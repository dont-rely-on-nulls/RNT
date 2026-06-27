#include <catch2/catch_test_macros.hpp>

#include "EphemeralRelation.h"
#include "InMemoryBackend.h"
#include "LifecycleManager.h"
#include "ObjectManager.h"

#include <memory>

// Ephemeral relations — writer path, tiered ownership, and GC cascade.
//
// nt::Ephemeral::Register lands an EPHEMERAL_RELATION in the object manager,
// pins the base relations it depends on, and (for the Named tier) takes a
// session-ownership pin so the entry outlives its cursor. Collection unpins
// the base relations via LifecycleManager::CascadeEphemeral.

namespace {
    using Card = nt::ObjectManager::ephemeral_object_type::Cardinality;

    std::unique_ptr<nt::ObjectManager::object_type> make_relation_type() {
        auto t = std::make_unique<nt::ObjectManager::object_type>();
        t->label = RELATION;
        t->methods = {OPEN, CLOSE};
        return t;
    }

    // Registers a stored base relation at the given registry path and sets its
    // merkle_root. Takes one baseline pin to model the owning multigroup
    // snapshot, so the relation survives an ephemeral releasing its own pin —
    // the reference_count then returns to 1 rather than dropping to 0 and being
    // collected. Returns the slash-joined logical path for use as a dependency.
    std::string make_base(nt::ObjectManager& om, nt::LifecycleManager& lm,
                          const std::vector<std::string>& path, const std::string& root) {
        auto rel = std::make_unique<nt::ObjectManager::Relation>();
        rel->merkle_root = root;
        om.Register(path, std::move(rel), make_relation_type());
        lm.Pin(om.Find(path)); // baseline pin: the snapshot that owns this relation
        std::string joined;
        for (const auto& seg : path) {
            if (!joined.empty())
                joined.push_back('/');
            joined += seg;
        }
        return joined;
    }

    // A trivial generator: yields nothing. Lifetime tests do not scan.
    nt::ObjectManager::ephemeral_object_type::Generator empty_generator() {
        return [](const std::vector<std::string>&, std::size_t, std::size_t) {
            return std::vector<nt::Tuple>{};
        };
    }
} // namespace

TEST_CASE("ComposeRoot is deterministic and order-independent", "[ephemeral][hash]") {
    const std::vector<std::pair<std::string, std::string>> schema_a = {{"left", "natural"},
                                                                       {"right", "natural"}};
    const std::vector<std::pair<std::string, std::string>> schema_b = {{"right", "natural"},
                                                                       {"left", "natural"}};

    const std::string h1 = nt::Ephemeral::ComposeRoot("eq", schema_a, {"aaa", "bbb"});
    const std::string h2 = nt::Ephemeral::ComposeRoot("eq", schema_b, {"bbb", "aaa"});
    REQUIRE(h1 == h2); // schema + base-root order must not matter
    REQUIRE(h1.size() == 64);

    // Identity, schema, or base roots each change the digest.
    REQUIRE(nt::Ephemeral::ComposeRoot("lt", schema_a, {"aaa", "bbb"}) != h1);
    REQUIRE(nt::Ephemeral::ComposeRoot("eq", schema_a, {"aaa", "ccc"}) != h1);
    REQUIRE(nt::Ephemeral::ComposeRoot("eq", {{"left", "natural"}}, {"aaa", "bbb"}) != h1);
}

TEST_CASE("Scratch tier pins deps but is not session-owned", "[ephemeral][scratch]") {
    nt::InMemoryBackend store;
    nt::ObjectManager om;
    nt::LifecycleManager lm(om, store);

    const std::string dep =
        make_base(om, lm, {"system", "snapshots", "h", "relations", "r1"}, "root1");

    auto* eph =
        nt::Ephemeral::Register(om, lm, "sess", nt::Ephemeral::Tier::Scratch, "", empty_generator(),
                                Card::Finite, "select", {{"a", "abstract"}}, {dep});
    REQUIRE(eph != nullptr);

    // Registered under the session's scratch subdir, keyed by composed root.
    REQUIRE(eph->head->path[0] == "system");
    REQUIRE(eph->head->path[3] == "scratch");

    // Base relation gains the ephemeral's pin atop its snapshot baseline (1+1);
    // the ephemeral itself carries no ownership pin.
    REQUIRE(om.Find({"system", "snapshots", "h", "relations", "r1"})->head->reference_count == 2);
    REQUIRE(eph->head->reference_count == 0);
}

TEST_CASE("Scratch ephemeral is collected by counters and unpins its base",
          "[ephemeral][scratch][gc]") {
    nt::InMemoryBackend store;
    nt::ObjectManager om;
    nt::LifecycleManager lm(om, store);

    const std::string dep =
        make_base(om, lm, {"system", "snapshots", "h", "relations", "r1"}, "root1");
    auto* eph =
        nt::Ephemeral::Register(om, lm, "sess", nt::Ephemeral::Tier::Scratch, "", empty_generator(),
                                Card::Finite, "select", {{"a", "abstract"}}, {dep});
    const auto eph_path = eph->head->path;

    // A cursor opens (Monitor) then closes (Unmonitor) over the scratch result.
    lm.Monitor(eph);
    REQUIRE(om.Find(eph_path) != nullptr);
    lm.Unmonitor(eph);

    // Gone by counters, and the cascade released the ephemeral's pin on the
    // base, returning it to its snapshot baseline (still alive at 1).
    REQUIRE(om.Find(eph_path) == nullptr);
    REQUIRE(om.Find({"system", "snapshots", "h", "relations", "r1"})->head->reference_count == 1);
}

TEST_CASE("Named ephemeral survives its cursor and is freed at session release",
          "[ephemeral][named][gc]") {
    nt::InMemoryBackend store;
    nt::ObjectManager om;
    nt::LifecycleManager lm(om, store);

    const std::string dep =
        make_base(om, lm, {"system", "snapshots", "h", "relations", "r1"}, "root1");
    auto* eph = nt::Ephemeral::Register(om, lm, "sess", nt::Ephemeral::Tier::Named, "myview",
                                        empty_generator(), Card::Finite, "join",
                                        {{"a", "abstract"}}, {dep});
    REQUIRE(eph != nullptr);
    REQUIRE(eph->head->path[3] == "ephemeral");
    REQUIRE(eph->head->path[4] == "myview");
    REQUIRE(eph->head->reference_count == 1); // session-ownership pin

    const auto eph_path = eph->head->path;

    // A cursor opens and closes; the session pin keeps the named view alive.
    lm.Monitor(eph);
    lm.Unmonitor(eph);
    REQUIRE(om.Find(eph_path) != nullptr);

    // Session close releases it; the base relation's pin cascades free.
    const std::size_t freed = nt::Ephemeral::ReleaseSession(om, lm, "sess");
    REQUIRE(freed == 1);
    REQUIRE(om.Find(eph_path) == nullptr);
    REQUIRE(om.Find({"system", "snapshots", "h", "relations", "r1"})->head->reference_count == 1);
}

TEST_CASE("Identical scratch results dedup and do not double-pin", "[ephemeral][dedup]") {
    nt::InMemoryBackend store;
    nt::ObjectManager om;
    nt::LifecycleManager lm(om, store);

    const std::string dep =
        make_base(om, lm, {"system", "snapshots", "h", "relations", "r1"}, "root1");

    auto* first =
        nt::Ephemeral::Register(om, lm, "sess", nt::Ephemeral::Tier::Scratch, "", empty_generator(),
                                Card::Finite, "select", {{"a", "abstract"}}, {dep});
    auto* second =
        nt::Ephemeral::Register(om, lm, "sess", nt::Ephemeral::Tier::Scratch, "", empty_generator(),
                                Card::Finite, "select", {{"a", "abstract"}}, {dep});

    REQUIRE(first == second); // same composed root → same entry
    // The ephemeral pinned the base exactly once (atop the baseline), not once
    // per Register call.
    REQUIRE(om.Find({"system", "snapshots", "h", "relations", "r1"})->head->reference_count == 2);
}
