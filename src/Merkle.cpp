#include "Merkle.h"

#include <algorithm>
#include <cassert>
#include <cstring>
#include <stdexcept>

namespace nt {

    // ── Wire format constants ────────────────────────────────────────────────────

    static constexpr uint8_t TAG_LEAF = 0x4C;     // 'L'
    static constexpr uint8_t TAG_INTERNAL = 0x49; // 'I'

    // ── Byte-order helpers ───────────────────────────────────────────────────────

    static void write_u32(std::vector<uint8_t>& buf, uint32_t v) {
        buf.push_back(static_cast<uint8_t>(v >> 24));
        buf.push_back(static_cast<uint8_t>(v >> 16));
        buf.push_back(static_cast<uint8_t>(v >> 8));
        buf.push_back(static_cast<uint8_t>(v));
    }

    static void write_u64(std::vector<uint8_t>& buf, uint64_t v) {
        buf.push_back(static_cast<uint8_t>(v >> 56));
        buf.push_back(static_cast<uint8_t>(v >> 48));
        buf.push_back(static_cast<uint8_t>(v >> 40));
        buf.push_back(static_cast<uint8_t>(v >> 32));
        buf.push_back(static_cast<uint8_t>(v >> 24));
        buf.push_back(static_cast<uint8_t>(v >> 16));
        buf.push_back(static_cast<uint8_t>(v >> 8));
        buf.push_back(static_cast<uint8_t>(v));
    }

    static uint32_t read_u32(const uint8_t* p) {
        return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) |
               uint32_t(p[3]);
    }

    static uint64_t read_u64(const uint8_t* p) {
        return (uint64_t(p[0]) << 56) | (uint64_t(p[1]) << 48) | (uint64_t(p[2]) << 40) |
               (uint64_t(p[3]) << 32) | (uint64_t(p[4]) << 24) | (uint64_t(p[5]) << 16) |
               (uint64_t(p[6]) << 8) | uint64_t(p[7]);
    }

    // ── Hex / binary conversion (free, key-agnostic) ─────────────────────────────

    Hash32 hex_to_bin(const std::string& hex) {
        if (hex.size() != 64)
            throw std::invalid_argument("Merkle: hash must be exactly 64 hex characters, got " +
                                        std::to_string(hex.size()));

        Hash32 out{};
        auto nibble = [](char c) -> uint8_t {
            if (c >= '0' && c <= '9')
                return static_cast<uint8_t>(c - '0');
            if (c >= 'a' && c <= 'f')
                return static_cast<uint8_t>(c - 'a' + 10);
            if (c >= 'A' && c <= 'F')
                return static_cast<uint8_t>(c - 'A' + 10);
            throw std::invalid_argument(std::string("Merkle: invalid hex character '") + c + "'");
        };
        for (size_t i = 0; i < 32; ++i)
            out[i] = static_cast<uint8_t>((nibble(hex[2 * i]) << 4) | nibble(hex[2 * i + 1]));
        return out;
    }

    std::string bin_to_hex(const Hash32& bin) {
        static const char HEX[] = "0123456789abcdef";
        std::string out(64, '0');
        for (size_t i = 0; i < 32; ++i) {
            out[2 * i] = HEX[(bin[i] >> 4) & 0xF];
            out[2 * i + 1] = HEX[bin[i] & 0xF];
        }
        return out;
    }

    // ── Key codec: per-Key serialisation primitives ──────────────────────────────

    namespace {

        template <typename Key> struct KeyCodec; // primary template intentionally undefined

        template <> struct KeyCodec<Hash32> {
            static void write(std::vector<uint8_t>& buf, const Hash32& k) {
                buf.insert(buf.end(), k.begin(), k.end());
            }
            // Returns key and advances *p_inout by the number of consumed bytes.
            static Hash32 read(const uint8_t*& p) {
                Hash32 k;
                std::memcpy(k.data(), p, 32);
                p += 32;
                return k;
            }
            static size_t encoded_size(const Hash32&) {
                return 32;
            }
        };

        template <> struct KeyCodec<std::string> {
            static void write(std::vector<uint8_t>& buf, const std::string& k) {
                write_u32(buf, static_cast<uint32_t>(k.size()));
                buf.insert(buf.end(), k.begin(), k.end());
            }
            static std::string read(const uint8_t*& p) {
                uint32_t len = read_u32(p);
                p += 4;
                std::string k(reinterpret_cast<const char*>(p), len);
                p += len;
                return k;
            }
            static size_t encoded_size(const std::string& k) {
                return 4 + k.size();
            }
        };

    } // anonymous namespace

    // ── Node serialisation ───────────────────────────────────────────────────────

    template <typename Key> std::vector<uint8_t> Merkle<Key>::encode_leaf(const LeafNode& n) {
        std::vector<uint8_t> buf;
        size_t payload_size = 0;
        for (const auto& e : n.entries)
            payload_size += KeyCodec<Key>::encoded_size(e.key) + 32;
        buf.reserve(1 + 4 + payload_size);

        buf.push_back(TAG_LEAF);
        write_u32(buf, static_cast<uint32_t>(n.entries.size()));
        for (const auto& e : n.entries) {
            KeyCodec<Key>::write(buf, e.key);
            buf.insert(buf.end(), e.payload.begin(), e.payload.end());
        }
        return buf;
    }

    template <typename Key>
    std::vector<uint8_t> Merkle<Key>::encode_internal(const InternalNode& n) {
        std::vector<uint8_t> buf;
        size_t payload_size = 0;
        for (const auto& e : n.entries)
            payload_size += 8 + KeyCodec<Key>::encoded_size(e.min_key) + 32;
        buf.reserve(1 + 4 + payload_size);

        buf.push_back(TAG_INTERNAL);
        write_u32(buf, static_cast<uint32_t>(n.entries.size()));
        for (const auto& e : n.entries) {
            write_u64(buf, e.leaf_count);
            KeyCodec<Key>::write(buf, e.min_key);
            buf.insert(buf.end(), e.child_hash.begin(), e.child_hash.end());
        }
        return buf;
    }

    template <typename Key>
    typename Merkle<Key>::LeafNode Merkle<Key>::decode_leaf(const std::vector<uint8_t>& bytes) {
        uint32_t count = read_u32(bytes.data() + 1);
        LeafNode n;
        n.entries.reserve(count);
        const uint8_t* p = bytes.data() + 5;
        for (uint32_t i = 0; i < count; ++i) {
            LeafEntry e;
            e.key = KeyCodec<Key>::read(p);
            std::memcpy(e.payload.data(), p, 32);
            p += 32;
            n.entries.push_back(std::move(e));
        }
        return n;
    }

    template <typename Key>
    typename Merkle<Key>::InternalNode
    Merkle<Key>::decode_internal(const std::vector<uint8_t>& bytes) {
        uint32_t count = read_u32(bytes.data() + 1);
        InternalNode n;
        n.entries.reserve(count);
        const uint8_t* p = bytes.data() + 5;
        for (uint32_t i = 0; i < count; ++i) {
            ChildEntry e;
            e.leaf_count = read_u64(p);
            p += 8;
            e.min_key = KeyCodec<Key>::read(p);
            std::memcpy(e.child_hash.data(), p, 32);
            p += 32;
            n.entries.push_back(std::move(e));
        }
        return n;
    }

    template <typename Key> bool Merkle<Key>::is_leaf_bytes(const std::vector<uint8_t>& bytes) {
        return !bytes.empty() && bytes[0] == TAG_LEAF;
    }

    // ── Storage helpers ──────────────────────────────────────────────────────────

    template <typename Key>
    std::vector<uint8_t> Merkle<Key>::load_node(IStorageBackend& store,
                                                const std::string& hash_hex) {
        auto opt = store.Get(hash_hex);
        if (!opt)
            throw std::runtime_error("Merkle: node not found: " + hash_hex);
        return std::move(*opt);
    }

    template <typename Key>
    std::string Merkle<Key>::store_leaf(IStorageBackend& store, const LeafNode& n) {
        return store.Put(encode_leaf(n));
    }

    template <typename Key>
    std::string Merkle<Key>::store_internal(IStorageBackend& store, const InternalNode& n) {
        return store.Put(encode_internal(n));
    }

    template <typename Key>
    Key Merkle<Key>::subtree_min_key(IStorageBackend& store, const std::string& node_hex) {
        auto bytes = load_node(store, node_hex);
        if (is_leaf_bytes(bytes)) {
            auto leaf = decode_leaf(bytes);
            assert(!leaf.entries.empty() && "Merkle invariant: leaf node must never be empty");
            return leaf.entries.front().key;
        }
        auto node = decode_internal(bytes);
        assert(!node.entries.empty() && "Merkle invariant: internal node must never be empty");
        return node.entries.front().min_key;
    }

    // ── Routing helper ───────────────────────────────────────────────────────────

    template <typename Key> size_t Merkle<Key>::route(const InternalNode& node, const Key& target) {
        assert(!node.entries.empty() && "Merkle invariant: internal node must never be empty");
        assert(std::is_sorted(node.entries.begin(), node.entries.end(),
                              [](const ChildEntry& a, const ChildEntry& b) {
                                  return a.min_key < b.min_key;
                              }) &&
               "Merkle invariant: internal node entries must be sorted by min_key");

        // Rightmost child whose min_key ≤ target.
        // Defaults to 0 (leftmost) when target < all min_keys.
        size_t idx = 0;
        for (size_t i = 1; i < node.entries.size(); ++i) {
            if (!(target < node.entries[i].min_key))
                idx = i;
            else
                break;
        }
        return idx;
    }

    // ── Insert ───────────────────────────────────────────────────────────────────

    template <typename Key>
    std::string Merkle<Key>::Insert(IStorageBackend& store, const std::string& root_hex,
                                    const Key& key, const Hash32& payload) {
        if (root_hex.empty()) {
            LeafNode leaf;
            leaf.entries.push_back({key, payload});
            return store_leaf(store, leaf);
        }

        auto result = insert_into(store, root_hex, key, payload);
        if (!result.did_split)
            return result.new_hash;

        // Root split: wrap both halves in a new internal root.
        Key left_min = subtree_min_key(store, result.new_hash);

        InternalNode new_root;

        ChildEntry left;
        left.leaf_count = result.leaf_count;
        left.min_key = left_min;
        left.child_hash = hex_to_bin(result.new_hash);
        new_root.entries.push_back(std::move(left));

        ChildEntry right;
        right.leaf_count = result.split_leaf_count;
        right.min_key = result.split_min_key;
        right.child_hash = hex_to_bin(result.split_hash);
        new_root.entries.push_back(std::move(right));

        return store_internal(store, new_root);
    }

    template <typename Key>
    typename Merkle<Key>::InsertResult
    Merkle<Key>::insert_into(IStorageBackend& store, const std::string& node_hex, const Key& key,
                             const Hash32& payload) {
        auto bytes = load_node(store, node_hex);

        // ── Leaf node ───────────────────────────────────────────────────────────
        if (is_leaf_bytes(bytes)) {
            auto leaf = decode_leaf(bytes);

            auto pos = std::lower_bound(leaf.entries.begin(), leaf.entries.end(), key,
                                        [](const LeafEntry& e, const Key& k) { return e.key < k; });
            if (pos != leaf.entries.end() && !(key < pos->key)) {
                // Key already present — update payload if it changed, else no-op.
                if (pos->payload == payload) {
                    InsertResult r;
                    r.new_hash = node_hex;
                    r.leaf_count = leaf.entries.size();
                    return r;
                }
                pos->payload = payload;
                InsertResult r;
                r.new_hash = store_leaf(store, leaf);
                r.leaf_count = leaf.entries.size();
                return r;
            }

            leaf.entries.insert(pos, LeafEntry{key, payload});

            if (leaf.entries.size() <= B) {
                InsertResult r;
                r.new_hash = store_leaf(store, leaf);
                r.leaf_count = leaf.entries.size();
                return r;
            }

            // Split leaf at midpoint.
            size_t mid = leaf.entries.size() / 2;
            LeafNode left_leaf, right_leaf;
            left_leaf.entries = {leaf.entries.begin(),
                                 leaf.entries.begin() + static_cast<ptrdiff_t>(mid)};
            right_leaf.entries = {leaf.entries.begin() + static_cast<ptrdiff_t>(mid),
                                  leaf.entries.end()};

            InsertResult r;
            r.new_hash = store_leaf(store, left_leaf);
            r.leaf_count = left_leaf.entries.size();
            r.did_split = true;
            r.split_leaf_count = right_leaf.entries.size();
            r.split_min_key = right_leaf.entries.front().key;
            r.split_hash = store_leaf(store, right_leaf);
            return r;
        }

        // ── Internal node ───────────────────────────────────────────────────────
        auto node = decode_internal(bytes);

        size_t child_idx = route(node, key);
        auto child_result =
            insert_into(store, bin_to_hex(node.entries[child_idx].child_hash), key, payload);

        node.entries[child_idx].leaf_count = child_result.leaf_count;
        node.entries[child_idx].child_hash = hex_to_bin(child_result.new_hash);

        // Update min_key for the modified child — only child 0 can have its min
        // decrease (routing guarantees min_key[i>0] ≤ inserted key, so inserting
        // below min_key[i>0] is impossible).
        if (child_idx == 0)
            node.entries[0].min_key = subtree_min_key(store, child_result.new_hash);

        uint64_t total = 0;
        for (const auto& e : node.entries)
            total += e.leaf_count;

        if (!child_result.did_split) {
            InsertResult r;
            r.new_hash = store_internal(store, node);
            r.leaf_count = total;
            return r;
        }

        // Insert the right sibling immediately after child_idx.
        ChildEntry sibling;
        sibling.leaf_count = child_result.split_leaf_count;
        sibling.min_key = child_result.split_min_key;
        sibling.child_hash = hex_to_bin(child_result.split_hash);
        node.entries.insert(node.entries.begin() + static_cast<ptrdiff_t>(child_idx) + 1,
                            std::move(sibling));
        total += child_result.split_leaf_count;

        if (node.entries.size() <= B) {
            InsertResult r;
            r.new_hash = store_internal(store, node);
            r.leaf_count = total;
            return r;
        }

        // Split this internal node.
        size_t mid = node.entries.size() / 2;
        InternalNode left_node, right_node;
        left_node.entries = {node.entries.begin(),
                             node.entries.begin() + static_cast<ptrdiff_t>(mid)};
        right_node.entries = {node.entries.begin() + static_cast<ptrdiff_t>(mid),
                              node.entries.end()};

        uint64_t left_count = 0, right_count = 0;
        for (const auto& e : left_node.entries)
            left_count += e.leaf_count;
        for (const auto& e : right_node.entries)
            right_count += e.leaf_count;

        InsertResult r;
        r.new_hash = store_internal(store, left_node);
        r.leaf_count = left_count;
        r.did_split = true;
        r.split_leaf_count = right_count;
        r.split_min_key = right_node.entries.front().min_key;
        r.split_hash = store_internal(store, right_node);
        return r;
    }

    // ── Remove ───────────────────────────────────────────────────────────────────

    template <typename Key>
    std::string Merkle<Key>::Remove(IStorageBackend& store, const std::string& root_hex,
                                    const Key& key) {
        if (root_hex.empty())
            return "";
        auto result = remove_from(store, root_hex, key);
        if (result.new_hash.empty())
            return "";

        // Collapse: if the root is an internal node with a single child, skip it.
        auto bytes = load_node(store, result.new_hash);
        if (!is_leaf_bytes(bytes)) {
            auto node = decode_internal(bytes);
            if (node.entries.size() == 1)
                return bin_to_hex(node.entries[0].child_hash);
        }
        return result.new_hash;
    }

    template <typename Key>
    typename Merkle<Key>::RemoveResult
    Merkle<Key>::remove_from(IStorageBackend& store, const std::string& node_hex, const Key& key) {
        auto bytes = load_node(store, node_hex);

        // ── Leaf node ───────────────────────────────────────────────────────────
        if (is_leaf_bytes(bytes)) {
            auto leaf = decode_leaf(bytes);
            auto it = std::lower_bound(leaf.entries.begin(), leaf.entries.end(), key,
                                       [](const LeafEntry& e, const Key& k) { return e.key < k; });
            if (it == leaf.entries.end() || key < it->key)
                return {node_hex, leaf.entries.size()}; // not found — no change

            leaf.entries.erase(it);
            if (leaf.entries.empty())
                return {"", 0};
            return {store_leaf(store, leaf), leaf.entries.size()};
        }

        // ── Internal node ───────────────────────────────────────────────────────
        auto node = decode_internal(bytes);

        size_t child_idx = route(node, key);
        auto child_result = remove_from(store, bin_to_hex(node.entries[child_idx].child_hash), key);

        if (child_result.new_hash.empty()) {
            node.entries.erase(node.entries.begin() + static_cast<ptrdiff_t>(child_idx));
            if (node.entries.empty())
                return {"", 0};
        } else {
            node.entries[child_idx].leaf_count = child_result.leaf_count;
            node.entries[child_idx].child_hash = hex_to_bin(child_result.new_hash);
            // The min of any child might have changed if we removed its minimum entry.
            node.entries[child_idx].min_key = subtree_min_key(store, child_result.new_hash);
        }

        uint64_t total = 0;
        for (const auto& e : node.entries)
            total += e.leaf_count;
        return {store_internal(store, node), total};
    }

    // ── Get ──────────────────────────────────────────────────────────────────────

    template <typename Key>
    std::optional<Hash32> Merkle<Key>::Get(IStorageBackend& store, const std::string& root_hex,
                                           const Key& key) {
        if (root_hex.empty())
            return std::nullopt;
        return get_from(store, root_hex, key);
    }

    template <typename Key>
    std::optional<Hash32> Merkle<Key>::get_from(IStorageBackend& store, const std::string& node_hex,
                                                const Key& key) {
        auto bytes = load_node(store, node_hex);
        if (is_leaf_bytes(bytes)) {
            auto leaf = decode_leaf(bytes);
            auto it = std::lower_bound(leaf.entries.begin(), leaf.entries.end(), key,
                                       [](const LeafEntry& e, const Key& k) { return e.key < k; });
            if (it == leaf.entries.end() || key < it->key)
                return std::nullopt;
            return it->payload;
        }
        auto node = decode_internal(bytes);
        size_t child_idx = route(node, key);
        return get_from(store, bin_to_hex(node.entries[child_idx].child_hash), key);
    }

    // ── Page ─────────────────────────────────────────────────────────────────────

    template <typename Key>
    std::vector<typename Merkle<Key>::Entry> Merkle<Key>::Page(IStorageBackend& store,
                                                               const std::string& root_hex,
                                                               size_t offset, size_t limit) {
        if (root_hex.empty() || limit == 0)
            return {};
        std::vector<Entry> out;
        out.reserve(limit);
        size_t skip = offset;
        page_from(store, root_hex, skip, limit, out);
        return out;
    }

    template <typename Key>
    void Merkle<Key>::page_from(IStorageBackend& store, const std::string& node_hex, size_t& offset,
                                size_t limit, std::vector<Entry>& out) {
        auto bytes = load_node(store, node_hex);

        if (is_leaf_bytes(bytes)) {
            auto leaf = decode_leaf(bytes);
            const size_t available = leaf.entries.size();

            if (offset >= available) {
                offset -= available;
                return;
            }

            for (size_t i = offset; i < available && out.size() < limit; ++i)
                out.push_back(Entry{leaf.entries[i].key, leaf.entries[i].payload});

            offset = 0;
            return;
        }

        auto node = decode_internal(bytes);

        for (const auto& entry : node.entries) {
            if (out.size() >= limit)
                break;

            if (offset >= entry.leaf_count) {
                offset -= entry.leaf_count;
                continue;
            }

            page_from(store, bin_to_hex(entry.child_hash), offset, limit, out);
        }
    }

    // ── Explicit instantiations ──────────────────────────────────────────────────

    template class Merkle<Hash32>;
    template class Merkle<std::string>;

} // namespace nt
