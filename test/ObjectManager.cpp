#include <catch2/catch_test_macros.hpp>

#include "ObjectManager.h"

#include <memory>

// ---------------------------------------------------------------------------
// Step 5 — Unregister
//
// Sessions are disposable and must be removable from the registry on close.
// Unregister is the splice-out primitive that rnt_session_close, the
// LifecycleManager TryCollect path, and any future explicit-delete API all
// share.
// ---------------------------------------------------------------------------

namespace {
    std::unique_ptr<nt::ObjectManager::object_type> session_type() {
        auto t = std::make_unique<nt::ObjectManager::object_type>();
        t->label = SESSION;
        t->disposable = true;
        t->methods = {OPEN, CLOSE};
        return t;
    }
} // namespace

TEST_CASE("Unregister removes the entry and Find returns nullptr", "[step5][object-manager]") {
    nt::ObjectManager om;
    om.Register({"system", "sessions", "alpha"}, std::make_unique<nt::ObjectManager::Session>(),
                session_type());
    REQUIRE(om.Find({"system", "sessions", "alpha"}) != nullptr);

    REQUIRE(om.Unregister({"system", "sessions", "alpha"}) == true);
    REQUIRE(om.Find({"system", "sessions", "alpha"}) == nullptr);
}

TEST_CASE("Unregister returns false for missing paths", "[step5][object-manager]") {
    nt::ObjectManager om;
    REQUIRE(om.Unregister({"never", "registered"}) == false);
}

TEST_CASE("Unregister splices a middle entry without disturbing neighbours",
          "[step5][object-manager]") {
    nt::ObjectManager om;
    om.Register({"a"}, std::make_unique<nt::ObjectManager::Session>(), session_type());
    om.Register({"b"}, std::make_unique<nt::ObjectManager::Session>(), session_type());
    om.Register({"c"}, std::make_unique<nt::ObjectManager::Session>(), session_type());

    REQUIRE(om.Unregister({"b"}) == true);

    REQUIRE(om.Find({"a"}) != nullptr);
    REQUIRE(om.Find({"b"}) == nullptr);
    REQUIRE(om.Find({"c"}) != nullptr);
}

TEST_CASE("Unregister at the head of the list works", "[step5][object-manager]") {
    nt::ObjectManager om;
    om.Register({"first"}, std::make_unique<nt::ObjectManager::Session>(), session_type());
    om.Register({"second"}, std::make_unique<nt::ObjectManager::Session>(), session_type());

    // The most recently registered entry is the list head (LIFO).
    REQUIRE(om.Unregister({"second"}) == true);
    REQUIRE(om.Find({"second"}) == nullptr);
    REQUIRE(om.Find({"first"}) != nullptr);

    // And the new head is removable too.
    REQUIRE(om.Unregister({"first"}) == true);
    REQUIRE(om.Find({"first"}) == nullptr);
}
