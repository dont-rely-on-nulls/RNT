#pragma once

#include "IStorageBackend.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

/**
 * @file Merkle.h
 * @brief Generic sorted content-addressed B-tree over a templated key type.
 *
 * Maps `Key → Hash32 payload` with `Key` totally ordered. Each tree node is
 * stored as an immutable blob in IStorageBackend via Put/Get. All operations
 * load only the nodes on the path from root to the target leaf — O(log_B(n))
 * nodes in memory at once, never the whole tree.
 *
 * Instantiated three times in RNT:
 *
 * | Level         | Key            | Payload (Hash32)        |
 * |---------------|----------------|-------------------------|
 * | Branch tree   | `std::string`  | multigroup snapshot hash|
 * | Multigroup    | `std::string`  | relation merkle root    |
 * | Relation      | `nt::Hash32`   | tuple hash (key=payload)|
 *
 * **Branching factor B = 64**. At 64 children per node and a billion leaves the
 * tree is at most 5 levels deep (~20 KB peak working set).
 *
 * **Immutability**: nodes are never overwritten once written (content-addressed).
 * Insert / Remove produce new nodes only along the modified path; old nodes
 * remain valid for any snapshot that still holds their root hash.
 *
 * **Leaf node** stores a sorted-by-key list of `(Key, Hash32 payload)` pairs,
 * length ≤ B. For the relation level the key and payload happen to carry the
 * same value (the tuple hash); callers pass it twice. Storing both keeps the
 * tree shape uniform across the three levels.
 *
 * **Internal node entry** layout (`leaf_count | min_key | child_hash`):
 *   - `leaf_count` enables O(log_B(n) + limit) offset navigation for Page()
 *     without loading sibling subtrees.
 *   - `min_key` is the smallest key in the subtree — the routing key.
 *   - `child_hash` is the content-addressed hash of the child node blob.
 *
 * **Invariants** (asserted in debug builds):
 *   - No leaf or internal node is ever empty.
 *   - Leaf entries are sorted ascending by key.
 *   - Internal entries are sorted ascending by min_key.
 *
 * **Wire format**: tagged 1-byte node kind ('L' or 'I'), then big-endian u32
 * count, then count repetitions of either a leaf entry or a child entry.
 * Key encoding is per-specialisation: `Hash32` is 32 raw bytes; `std::string`
 * is `u32_be length | bytes`. Wire format is content-addressed — any change
 * here invalidates every existing stored snapshot.
 */

namespace nt {

    /** @brief 32-byte hash, the universal payload type for all merkle levels. */
    using Hash32 = std::array<uint8_t, 32>;

    /** @brief Decode a 64-character lowercase-hex SHA256 string into raw bytes.
     *  Throws std::invalid_argument when the string is not exactly 64 hex chars. */
    Hash32 hex_to_bin(const std::string& hex);

    /** @brief Encode raw 32 bytes back into a 64-character lowercase-hex string. */
    std::string bin_to_hex(const Hash32& bin);

    template <typename Key> class Merkle {
      public:
        static constexpr size_t B = 64;

        /**
         * @brief Insert or overwrite a `(key, payload)` mapping.
         * @param store     KV backend for node serialisation.
         * @param root_hex  Current root hash (empty string = empty tree).
         * @param key       Routing/identity key.
         * @param payload   Hash this key maps to (child root one level down, or
         *                  the key itself at the relation level).
         * @return New root hash. Equal to root_hex when an insertion of an
         *         identical (key, payload) pair would be a no-op.
         */
        static std::string Insert(IStorageBackend& store, const std::string& root_hex,
                                  const Key& key, const Hash32& payload);

        /**
         * @brief Remove a key from the tree.
         * @return New root hash. Empty string when the tree becomes empty.
         *         Equal to root_hex when the key is absent.
         */
        static std::string Remove(IStorageBackend& store, const std::string& root_hex,
                                  const Key& key);

        /**
         * @brief Look up the payload for a key.
         * @return The payload when present, std::nullopt when absent.
         */
        static std::optional<Hash32> Get(IStorageBackend& store, const std::string& root_hex,
                                         const Key& key);

        /** @brief One (key, payload) pair returned by Page(). */
        struct Entry {
            Key key;
            Hash32 payload;
        };

        /**
         * @brief Page through entries in key-sorted order.
         *
         * Descends to the leaf at logical position @p offset using cumulative
         * leaf_counts stored in internal nodes, then walks forward collecting at
         * most @p limit entries. Only the nodes on the active path are loaded;
         * sibling subtrees are never touched.
         */
        static std::vector<Entry> Page(IStorageBackend& store, const std::string& root_hex,
                                       size_t offset, size_t limit);

      private:
        struct LeafEntry {
            Key key;
            Hash32 payload;
        };

        struct LeafNode {
            std::vector<LeafEntry> entries;
        };

        struct ChildEntry {
            uint64_t leaf_count;
            Key min_key;
            Hash32 child_hash;
        };

        struct InternalNode {
            std::vector<ChildEntry> entries;
        };

        // Wire format
        static std::vector<uint8_t> encode_leaf(const LeafNode& n);
        static std::vector<uint8_t> encode_internal(const InternalNode& n);
        static LeafNode decode_leaf(const std::vector<uint8_t>& bytes);
        static InternalNode decode_internal(const std::vector<uint8_t>& bytes);
        static bool is_leaf_bytes(const std::vector<uint8_t>& bytes);

        // Storage helpers
        static std::vector<uint8_t> load_node(IStorageBackend& store, const std::string& hash_hex);
        static std::string store_leaf(IStorageBackend& store, const LeafNode& n);
        static std::string store_internal(IStorageBackend& store, const InternalNode& n);

        /** @brief Returns the smallest key in the subtree rooted at @p node_hex. */
        static Key subtree_min_key(IStorageBackend& store, const std::string& node_hex);

        /** @brief Routes a key to the rightmost child whose min_key ≤ target. */
        static size_t route(const InternalNode& node, const Key& target);

        struct InsertResult {
            std::string new_hash;
            uint64_t leaf_count = 0;
            bool did_split = false;
            uint64_t split_leaf_count = 0;
            Key split_min_key{};
            std::string split_hash;
        };

        static InsertResult insert_into(IStorageBackend& store, const std::string& node_hex,
                                        const Key& key, const Hash32& payload);

        struct RemoveResult {
            std::string new_hash;
            uint64_t leaf_count = 0;
        };

        static RemoveResult remove_from(IStorageBackend& store, const std::string& node_hex,
                                        const Key& key);

        static void page_from(IStorageBackend& store, const std::string& node_hex, size_t& offset,
                              size_t limit, std::vector<Entry>& out);

        static std::optional<Hash32> get_from(IStorageBackend& store, const std::string& node_hex,
                                              const Key& key);
    };

} // namespace nt
