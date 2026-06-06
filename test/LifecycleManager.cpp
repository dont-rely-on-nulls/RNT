#include <catch2/catch_test_macros.hpp>

#include "InMemoryBackend.h"
#include "LifecycleManager.h"
#include "ObjectManager.h"

#include <memory>

// ---------------------------------------------------------------------------
// Step 6 — Pin/Unpin and the cascade
//
// LifecycleManager owns object lifetime. Pin/Unpin adjust reference_count;
// Monitor/Unmonitor adjust handle_count. Both decrement paths call into
// TryCollect, which gates GC on the joint condition (both counters zero)
// and, for MULTIGROUP entries, cascades through CascadeMultigroup to
// unpin every Relation registered under their snapshot subtree.
// ---------------------------------------------------------------------------

namespace {
    std::unique_ptr<nt::ObjectManager::object_type> make_type(OBJECT_TYPE label) {
        auto t = std::make_unique<nt::ObjectManager::object_type>();
        t->label = label;
        t->methods = {OPEN, CLOSE};
        return t;
    }
} // namespace

TEST_CASE("Pin and Unpin adjust reference_count symmetrically", "[step6][lifecycle][pin]") {
    nt::InMemoryBackend store;
    nt::ObjectManager om;
    nt::LifecycleManager lm(om, store);
    om.Register({"r1"}, std::make_unique<nt::ObjectManager::Relation>(), make_type(RELATION));
    auto* entry = om.Find({"r1"});
    REQUIRE(entry->head->reference_count == 0);

    lm.Pin(entry);
    lm.Pin(entry);
    REQUIRE(entry->head->reference_count == 2);

    lm.Unpin(entry);
    REQUIRE(entry->head->reference_count == 1);

    // Still alive at ref_count=1.
    REQUIRE(om.Find({"r1"}) != nullptr);
}

TEST_CASE("Pin on nullptr is a no-op", "[step6][lifecycle][pin]") {
    nt::InMemoryBackend store;
    nt::ObjectManager om;
    nt::LifecycleManager lm(om, store);
    REQUIRE_NOTHROW(lm.Pin(nullptr));
    REQUIRE_NOTHROW(lm.Unpin(nullptr));
}

TEST_CASE("Unpin below zero does not underflow", "[step6][lifecycle][pin]") {
    nt::InMemoryBackend store;
    nt::ObjectManager om;
    nt::LifecycleManager lm(om, store);
    om.Register({"r1"}, std::make_unique<nt::ObjectManager::Relation>(), make_type(RELATION));
    auto* entry = om.Find({"r1"});

    lm.Unpin(entry);
    REQUIRE(entry->head->reference_count == 0);
}

TEST_CASE("GC is gated on both counters reaching zero", "[step6][lifecycle][gc]") {
    nt::InMemoryBackend store;
    nt::ObjectManager om;
    nt::LifecycleManager lm(om, store);
    om.Register({"r1"}, std::make_unique<nt::ObjectManager::Relation>(), make_type(RELATION));
    auto* entry = om.Find({"r1"});

    lm.Monitor(entry);
    lm.Pin(entry);

    // handle_count=1, ref_count=1.
    lm.Unpin(entry); // ref_count → 0, but handle_count still 1.
    REQUIRE(om.Find({"r1"}) != nullptr);

    lm.Pin(entry);
    lm.Unmonitor(entry); // handle_count → 0, but ref_count still 1.
    REQUIRE(om.Find({"r1"}) != nullptr);

    lm.Unpin(entry); // both zero → GC.
    REQUIRE(om.Find({"r1"}) == nullptr);
}

TEST_CASE("Unmonitor that brings both counters to zero collects the entry",
          "[step6][lifecycle][gc]") {
    nt::InMemoryBackend store;
    nt::ObjectManager om;
    nt::LifecycleManager lm(om, store);
    om.Register({"r1"}, std::make_unique<nt::ObjectManager::Relation>(), make_type(RELATION));
    auto* entry = om.Find({"r1"});

    lm.Monitor(entry);
    REQUIRE(entry->head->handle_count == 1);
    lm.Unmonitor(entry);
    REQUIRE(om.Find({"r1"}) == nullptr);
}

TEST_CASE("IsEligibleForGC reflects the joint-zero rule", "[step6][lifecycle][gc]") {
    nt::InMemoryBackend store;
    nt::ObjectManager om;
    nt::LifecycleManager lm(om, store);
    om.Register({"r1"}, std::make_unique<nt::ObjectManager::Relation>(), make_type(RELATION));
    auto* entry = om.Find({"r1"});

    REQUIRE(lm.IsEligibleForGC(entry));
    lm.Pin(entry);
    REQUIRE_FALSE(lm.IsEligibleForGC(entry));
}

TEST_CASE("CascadeMultigroup unpins child Relations on snapshot collection",
          "[step6][lifecycle][cascade]") {
    nt::InMemoryBackend store;
    nt::ObjectManager om;
    nt::LifecycleManager lm(om, store);

    om.Register({"system", "snapshots", "H1"}, std::make_unique<nt::ObjectManager::Multigroup>(),
                make_type(MULTIGROUP));
    auto* mg_entry = om.Find({"system", "snapshots", "H1"});

    for (const auto& n : {std::string{"foo"}, std::string{"bar"}}) {
        om.Register({"system", "snapshots", "H1", "relations", n},
                    std::make_unique<nt::ObjectManager::Relation>(), make_type(RELATION));
        // The parent Multigroup's pin on each child, mirroring what
        // register_snapshot does in the C API layer.
        lm.Pin(om.Find({"system", "snapshots", "H1", "relations", n}));
    }
    REQUIRE(om.Find({"system", "snapshots", "H1", "relations", "foo"}) != nullptr);
    REQUIRE(om.Find({"system", "snapshots", "H1", "relations", "bar"}) != nullptr);

    // One external pin on the Multigroup (e.g. a branch). Release it: cascade.
    lm.Pin(mg_entry);
    lm.Unpin(mg_entry);

    REQUIRE(om.Find({"system", "snapshots", "H1"}) == nullptr);
    REQUIRE(om.Find({"system", "snapshots", "H1", "relations", "foo"}) == nullptr);
    REQUIRE(om.Find({"system", "snapshots", "H1", "relations", "bar"}) == nullptr);
}

TEST_CASE("Cascade survives a child with an open handle", "[step6][lifecycle][cascade]") {
    nt::InMemoryBackend store;
    nt::ObjectManager om;
    nt::LifecycleManager lm(om, store);

    om.Register({"system", "snapshots", "H2"}, std::make_unique<nt::ObjectManager::Multigroup>(),
                make_type(MULTIGROUP));
    auto* mg_entry = om.Find({"system", "snapshots", "H2"});

    om.Register({"system", "snapshots", "H2", "relations", "live"},
                std::make_unique<nt::ObjectManager::Relation>(), make_type(RELATION));
    auto* child = om.Find({"system", "snapshots", "H2", "relations", "live"});
    lm.Pin(child);     // parent's pin
    lm.Monitor(child); // simulate an open handle on the child

    // Drop the Multigroup's external ref: cascade unpins child (ref → 0),
    // but handle_count is still 1 — child must survive.
    lm.Pin(mg_entry);
    lm.Unpin(mg_entry);

    REQUIRE(om.Find({"system", "snapshots", "H2"}) == nullptr);
    REQUIRE(om.Find({"system", "snapshots", "H2", "relations", "live"}) != nullptr);

    // Closing the handle now releases the child.
    lm.Unmonitor(child);
    REQUIRE(om.Find({"system", "snapshots", "H2", "relations", "live"}) == nullptr);
}
