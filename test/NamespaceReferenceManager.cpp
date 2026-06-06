#include <catch2/catch_test_macros.hpp>

#include "InMemoryBackend.h"
#include "Merkle.h"
#include "NamespaceReferenceManager.h"
#include "ObjectManager.h"

#include <memory>

// ---------------------------------------------------------------------------
// Resolver — two-level reparse through the branch tree.
//
// NamespaceReferenceManager::Resolve rewrites
//   /system/branches/<name>/multigroups/<mg>/<sub>...
// into
//   /system/snapshots/<mg_hash>/<sub>...
// by reading branch.target_hash (a Merkle<string> root) from storage and
// looking up <mg>. Session paths consult the per-session override map first
// and fall back to the global branch when no override is set.
// ---------------------------------------------------------------------------

namespace {

    using Path = std::vector<std::string>;

    // Pad a label into a deterministic 64-char hex string so the merkle codec can
    // decode it as a 32-byte payload.
    std::string mk_hash(char c, char d = '0') {
        std::string h(64, '0');
        h[0] = c;
        h[1] = d;
        return h;
    }

    std::unique_ptr<nt::ObjectManager::object_type> make_type(OBJECT_TYPE label) {
        auto t = std::make_unique<nt::ObjectManager::object_type>();
        t->label = label;
        t->methods = {OPEN, CLOSE};
        return t;
    }

    void register_branch(nt::ObjectManager& om, const std::string& name,
                         const std::string& target_hash) {
        auto br = std::make_unique<nt::ObjectManager::Branch>();
        br->name = name;
        br->target_hash = target_hash;
        om.Register({"system", "branches", name}, std::move(br), make_type(BRANCH));
    }

    void register_session(nt::ObjectManager& om, const std::string& id,
                          std::map<std::string, std::string> overrides = {}) {
        auto s = std::make_unique<nt::ObjectManager::Session>();
        s->branch_overrides = std::move(overrides);
        om.Register({"system", "sessions", id}, std::move(s), make_type(SESSION));
    }

    // Builds a branch tree with a single (mg_name → mg_hash) entry. Returns the
    // branch-tree root hex.
    std::string build_branch_tree(nt::InMemoryBackend& store, const std::string& mg_name,
                                  const std::string& mg_hash_hex) {
        return nt::Merkle<std::string>::Insert(store, "", mg_name, nt::hex_to_bin(mg_hash_hex));
    }

} // namespace

TEST_CASE("Branch sub-path rewrites through the branch tree to the mg snapshot", "[resolve]") {
    nt::ObjectManager om;
    nt::InMemoryBackend store;

    const std::string mg_hash = mk_hash('a');
    const std::string tree = build_branch_tree(store, "warehouse", mg_hash);
    register_branch(om, "main", tree);

    nt::NamespaceReferenceManager nrm(om, store);
    REQUIRE(nrm.Resolve({"system", "branches", "main", "multigroups", "warehouse", "relations",
                         "items"}) == Path{"system", "snapshots", mg_hash, "relations", "items"});
}

TEST_CASE("Resolve on the branch object itself is left unchanged", "[resolve]") {
    nt::ObjectManager om;
    nt::InMemoryBackend store;
    const std::string tree = build_branch_tree(store, "warehouse", mk_hash('a'));
    register_branch(om, "main", tree);

    nt::NamespaceReferenceManager nrm(om, store);
    const Path p{"system", "branches", "main"};
    REQUIRE(nrm.Resolve(p) == p);
}

TEST_CASE("Resolve on an unborn branch leaves the path unchanged", "[resolve]") {
    nt::ObjectManager om;
    nt::InMemoryBackend store;
    register_branch(om, "main", ""); // unborn

    nt::NamespaceReferenceManager nrm(om, store);
    const Path p{"system", "branches", "main", "multigroups", "warehouse", "relations", "items"};
    REQUIRE(nrm.Resolve(p) == p);
}

TEST_CASE("Resolve on an absent multigroup leaves the path unchanged", "[resolve]") {
    nt::ObjectManager om;
    nt::InMemoryBackend store;
    const std::string tree = build_branch_tree(store, "warehouse", mk_hash('a'));
    register_branch(om, "main", tree);

    nt::NamespaceReferenceManager nrm(om, store);
    const Path p{"system", "branches", "main", "multigroups", "audit", "relations", "events"};
    REQUIRE(nrm.Resolve(p) == p);
}

TEST_CASE("Resolve on an unknown branch leaves the path unchanged", "[resolve]") {
    nt::ObjectManager om;
    nt::InMemoryBackend store;
    nt::NamespaceReferenceManager nrm(om, store);
    const Path p{"system", "branches", "ghost", "multigroups", "warehouse", "relations", "items"};
    REQUIRE(nrm.Resolve(p) == p);
}

TEST_CASE("Non-branch paths pass through unchanged", "[resolve]") {
    nt::ObjectManager om;
    nt::InMemoryBackend store;
    nt::NamespaceReferenceManager nrm(om, store);
    const Path p{"relations", "anywhere"};
    REQUIRE(nrm.Resolve(p) == p);
}

TEST_CASE("Session override takes precedence over the global branch HEAD", "[resolve]") {
    nt::ObjectManager om;
    nt::InMemoryBackend store;

    const std::string mg_global = mk_hash('a');
    const std::string mg_session = mk_hash('b');
    const std::string tree_global = build_branch_tree(store, "warehouse", mg_global);
    const std::string tree_session = build_branch_tree(store, "warehouse", mg_session);

    register_branch(om, "main", tree_global);
    register_session(om, "sess123", {{"main", tree_session}});

    nt::NamespaceReferenceManager nrm(om, store);
    REQUIRE(nrm.Resolve({"system", "sessions", "sess123", "branches", "main", "multigroups",
                         "warehouse", "relations", "items"}) ==
            Path{"system", "snapshots", mg_session, "relations", "items"});
}

TEST_CASE("Session resolution falls back to global branch when override is absent", "[resolve]") {
    nt::ObjectManager om;
    nt::InMemoryBackend store;

    const std::string mg_global = mk_hash('a');
    const std::string tree_global = build_branch_tree(store, "warehouse", mg_global);

    register_branch(om, "main", tree_global);
    register_session(om, "sess123"); // no overrides

    nt::NamespaceReferenceManager nrm(om, store);
    REQUIRE(nrm.Resolve({"system", "sessions", "sess123", "branches", "main", "multigroups",
                         "warehouse", "relations", "items"}) ==
            Path{"system", "snapshots", mg_global, "relations", "items"});
}

TEST_CASE("Session resolution with neither override nor global branch is unchanged", "[resolve]") {
    nt::ObjectManager om;
    nt::InMemoryBackend store;
    register_session(om, "sess123");

    nt::NamespaceReferenceManager nrm(om, store);
    const Path p{"system",      "sessions",  "sess123",   "branches", "main",
                 "multigroups", "warehouse", "relations", "items"};
    REQUIRE(nrm.Resolve(p) == p);
}

TEST_CASE("Empty input path is returned unchanged", "[resolve]") {
    nt::ObjectManager om;
    nt::InMemoryBackend store;
    nt::NamespaceReferenceManager nrm(om, store);
    REQUIRE(nrm.Resolve({}).empty());
}
