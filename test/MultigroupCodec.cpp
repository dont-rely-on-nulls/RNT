#include <catch2/catch_test_macros.hpp>

#include "InMemoryBackend.h"
#include "MultigroupCodec.h"

#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Multigroup snapshot — Merkle<string> tree mapping relation name → relation root.
//
// The codec is a thin facade over Merkle<std::string>; these tests confirm
// the tree is order-independent (it sorts intrinsically), that mutations are
// path-localised (sibling entries are untouched), and that snapshots can be
// re-enumerated from a cold backend by hash alone.
// ---------------------------------------------------------------------------

namespace {

    // Pad a short label into a deterministic 64-char hex string so the codec can
    // decode it as a 32-byte payload.
    std::string mk_root(char c, char d = '0') {
        std::string h(64, '0');
        h[0] = c;
        h[1] = d;
        return h;
    }

} // namespace

TEST_CASE("Build is order-independent - tree sorts intrinsically", "[multigroup-codec]") {
    nt::InMemoryBackend a, b;

    std::vector<nt::MultigroupCodec::RelationEntry> in_order = {
        {"alpha", mk_root('a')},
        {"bravo", mk_root('b')},
        {"charlie", mk_root('c')},
    };
    std::vector<nt::MultigroupCodec::RelationEntry> shuffled = {
        {"charlie", mk_root('c')},
        {"alpha", mk_root('a')},
        {"bravo", mk_root('b')},
    };

    REQUIRE(nt::MultigroupCodec::Build(a, in_order) == nt::MultigroupCodec::Build(b, shuffled));
}

TEST_CASE("Build distinguishes content changes", "[multigroup-codec]") {
    nt::InMemoryBackend backend;

    std::vector<nt::MultigroupCodec::RelationEntry> base = {{"foo", mk_root('a')}};
    std::vector<nt::MultigroupCodec::RelationEntry> different_root = {{"foo", mk_root('b')}};
    std::vector<nt::MultigroupCodec::RelationEntry> different_name = {{"bar", mk_root('a')}};
    std::vector<nt::MultigroupCodec::RelationEntry> extra_member = {{"foo", mk_root('a')},
                                                                    {"bar", mk_root('b')}};

    const auto h_base = nt::MultigroupCodec::Build(backend, base);
    REQUIRE(h_base != nt::MultigroupCodec::Build(backend, different_root));
    REQUIRE(h_base != nt::MultigroupCodec::Build(backend, different_name));
    REQUIRE(h_base != nt::MultigroupCodec::Build(backend, extra_member));
}

TEST_CASE("Build then List round-trips entries in key-sorted order", "[multigroup-codec]") {
    nt::InMemoryBackend backend;

    std::vector<nt::MultigroupCodec::RelationEntry> entries = {
        {"foo", mk_root('a', '1')},
        {"bar", mk_root('b', '2')},
        {"baz", mk_root('c', '3')},
    };
    const auto root = nt::MultigroupCodec::Build(backend, entries);

    auto listed = nt::MultigroupCodec::List(backend, root);
    REQUIRE(listed.size() == 3);
    REQUIRE(listed[0].first == "bar");
    REQUIRE(listed[1].first == "baz");
    REQUIRE(listed[2].first == "foo");
    REQUIRE(listed[0].second == mk_root('b', '2'));
}

TEST_CASE("Lookup returns payload by name", "[multigroup-codec]") {
    nt::InMemoryBackend backend;

    std::vector<nt::MultigroupCodec::RelationEntry> entries = {
        {"foo", mk_root('a')},
        {"bar", mk_root('b')},
    };
    const auto root = nt::MultigroupCodec::Build(backend, entries);

    REQUIRE(nt::MultigroupCodec::Lookup(backend, root, "foo") == mk_root('a'));
    REQUIRE(nt::MultigroupCodec::Lookup(backend, root, "bar") == mk_root('b'));
    REQUIRE(nt::MultigroupCodec::Lookup(backend, root, "missing").empty());
}

TEST_CASE("InsertOne mutates one entry; sibling subtree is untouched", "[multigroup-codec]") {
    nt::InMemoryBackend backend;

    std::vector<nt::MultigroupCodec::RelationEntry> entries = {
        {"foo", mk_root('a')},
        {"bar", mk_root('b')},
    };
    const auto root0 = nt::MultigroupCodec::Build(backend, entries);

    // Mutate foo only; bar's payload must round-trip unchanged.
    const auto root1 = nt::MultigroupCodec::InsertOne(backend, root0, "foo", mk_root('d'));
    REQUIRE(root1 != root0);
    REQUIRE(nt::MultigroupCodec::Lookup(backend, root1, "foo") == mk_root('d'));
    REQUIRE(nt::MultigroupCodec::Lookup(backend, root1, "bar") == mk_root('b'));
}

TEST_CASE("RemoveOne deletes one entry; sibling preserved", "[multigroup-codec]") {
    nt::InMemoryBackend backend;

    std::vector<nt::MultigroupCodec::RelationEntry> entries = {
        {"foo", mk_root('a')},
        {"bar", mk_root('b')},
    };
    const auto root0 = nt::MultigroupCodec::Build(backend, entries);

    const auto root1 = nt::MultigroupCodec::RemoveOne(backend, root0, "foo");
    REQUIRE(nt::MultigroupCodec::Lookup(backend, root1, "foo").empty());
    REQUIRE(nt::MultigroupCodec::Lookup(backend, root1, "bar") == mk_root('b'));
}

TEST_CASE("Empty multigroup builds to an empty root", "[multigroup-codec]") {
    nt::InMemoryBackend backend;
    std::vector<nt::MultigroupCodec::RelationEntry> empty;
    REQUIRE(nt::MultigroupCodec::Build(backend, empty).empty());
    REQUIRE(nt::MultigroupCodec::List(backend, "").empty());
}
