#include <catch2/catch_test_macros.hpp>

#include "CursorManager.h"
#include "HandlerManager.h"
#include "IdentityManager.h"
#include "InMemoryBackend.h"
#include "LifecycleManager.h"
#include "Merkle.h"
#include "MultigroupCodec.h"
#include "NamespaceReferenceManager.h"
#include "ObjectManager.h"
#include "PermissionsManager.h"
#include "TupleCodec.h"

#include <memory>

// ---------------------------------------------------------------------------
// Step 6 / cursor-independence follow-up
//
// Two things to verify:
//   1. A cursor opened on a /system/snapshots/<H>/relations/<n> relation
//      pins the parent Multigroup for its lifetime; releasing the cursor
//      releases the pin.
//   2. Closing the handle a cursor was opened from no longer dereferences
//      a freed handle pointer inside Next() — the cursor captures the type
//      label and the ephemeral generator at Open time, so iteration after
//      the handle's death is degenerate but safe.
// ---------------------------------------------------------------------------

namespace {
    std::unique_ptr<nt::ObjectManager::object_type> make_type(OBJECT_TYPE label) {
        auto t = std::make_unique<nt::ObjectManager::object_type>();
        t->label = label;
        t->methods = {OPEN, CLOSE};
        return t;
    }

    std::unique_ptr<nt::ObjectManager::ephemeral_object_type>
    make_constant_eph_type(std::vector<nt::Attribute> attrs) {
        auto t = std::make_unique<nt::ObjectManager::ephemeral_object_type>();
        t->label = EPHEMERAL_RELATION;
        t->methods = {OPEN, CLOSE};
        t->cardinality = nt::ObjectManager::ephemeral_object_type::Cardinality::Finite;
        t->generator = [attrs](const std::vector<std::string>&, std::size_t offset,
                               std::size_t limit) -> std::vector<nt::Tuple> {
            if (offset > 0 || limit == 0)
                return {};
            return {nt::Tuple(attrs)};
        };
        return t;
    }

    struct Stack {
        nt::InMemoryBackend backend;
        nt::ObjectManager objects;
        nt::PermissionsManager permissions;
        nt::IdentityManager identities;
        nt::LifecycleManager lifecycles{objects, backend};
        nt::NamespaceReferenceManager references{objects, backend};
        nt::HandlerManager handler{objects, permissions, identities, lifecycles, references};
        nt::CursorManager cursors{backend, &lifecycles, &objects};
    };
} // namespace

TEST_CASE("Cursor pins the parent snapshot and unpins on close", "[step6][cursor][pin]") {
    Stack s;

    // Stand up a minimal snapshot with one relation.
    auto& om = s.objects;
    om.Register({"system", "snapshots", "Hcur"}, std::make_unique<nt::ObjectManager::Multigroup>(),
                make_type(MULTIGROUP));
    om.Register({"system", "snapshots", "Hcur", "relations", "items"},
                std::make_unique<nt::ObjectManager::Relation>(), make_type(RELATION));

    auto* mg_entry = om.Find({"system", "snapshots", "Hcur"});
    auto* rel_entry = om.Find({"system", "snapshots", "Hcur", "relations", "items"});

    // Parent's pin on the child Relation (mirrors register_snapshot in the C
    // API). An external pin on the Multigroup simulates a branch holding the
    // snapshot — without it, closing the cursor would drop ref_count to 0 and
    // cascade-collect mg_entry mid-test.
    s.lifecycles.Pin(rel_entry);
    s.lifecycles.Pin(mg_entry);

    // Open a handle and a cursor on the child Relation.
    int conn = 1;
    auto* h = s.handler.Open({"system", "snapshots", "Hcur", "relations", "items"}, &conn);
    REQUIRE(h != nullptr);
    REQUIRE(mg_entry->head->reference_count == 1); // external pin only

    auto* c = s.cursors.Open(h);
    REQUIRE(c != nullptr);
    REQUIRE(c->pinned_snapshot == mg_entry);
    REQUIRE(mg_entry->head->reference_count == 2); // external + cursor pin

    s.cursors.Close(c);
    REQUIRE(mg_entry->head->reference_count == 1); // back to external only

    s.handler.Close(h);
    s.lifecycles.Unpin(mg_entry); // releases the external pin; cascade-collects.
}

TEST_CASE("Closing the handle mid-iteration does not crash an ephemeral cursor",
          "[step6][cursor][handle-independence]") {
    Stack s;
    // Register an ephemeral relation; its generator yields one tuple.
    s.objects.Register({"eph"}, std::make_unique<nt::ObjectManager::Relation>(),
                       make_constant_eph_type({{"k", "v"}}));

    int conn = 1;
    auto* h = s.handler.Open({"eph"}, &conn);
    REQUIRE(h != nullptr);
    auto* c = s.cursors.Open(h);
    REQUIRE(c != nullptr);

    // Ephemeral cursors start exhausted; reset to simulate a JOIN probe.
    c->exhausted = false;
    c->args = {};

    // Now violate the documented contract: close the handle BEFORE Next().
    // The cursor must still produce its tuple from the captured generator
    // without dereferencing the freed handle.
    s.handler.Close(h);

    auto* tuple = s.cursors.Next(c);
    REQUIRE(tuple != nullptr);
    bool found = false;
    for (const auto& a : tuple->attrs())
        if (a.name == "k" && a.value == "v") {
            found = true;
            break;
        }
    REQUIRE(found);

    s.cursors.Close(c);
}

TEST_CASE("Cursor opened against a non-snapshot relation does not pin anything",
          "[step6][cursor][pin]") {
    Stack s;
    s.objects.Register({"plain", "rel"}, std::make_unique<nt::ObjectManager::Relation>(),
                       make_type(RELATION));
    int conn = 1;
    auto* h = s.handler.Open({"plain", "rel"}, &conn);
    REQUIRE(h != nullptr);
    auto* c = s.cursors.Open(h);
    REQUIRE(c != nullptr);
    REQUIRE(c->pinned_snapshot == nullptr);

    s.cursors.Close(c);
    s.handler.Close(h);
}
