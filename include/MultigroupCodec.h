#pragma once

#include "IStorageBackend.h"

#include <string>
#include <utility>
#include <vector>

/**
 * @file MultigroupCodec.h
 * @brief Thin facade over Merkle<std::string> for multigroup snapshots.
 *
 * A multigroup snapshot is a `Merkle<std::string>` B-tree mapping each
 * relation name to that relation's merkle root. The snapshot identifier is
 * the hex hash of the tree's root node — the same path-localised content
 * addressing used at the tuple level inside each relation.
 *
 * Stored relations and ephemeral relations are represented uniformly: only
 * the relation's name and its current merkle_root participate in the tree,
 * regardless of how that root was derived.
 *
 * The codec used to be a flat `SHA256(sorted [(name, root)])` over a single
 * blob. That collapsed all relations into one rehash on any mutation. With
 * the merkle B-tree, a single relation update touches `O(log_B(n_rels))`
 * nodes on the way to the new root — sibling subtrees stay byte-identical.
 *
 * `RelationEntry` is `(relation_name, relation_root_hex)`. Both forms are
 * hex strings on the wire; the codec hex-decodes internally before handing
 * payloads to `Merkle<std::string>`.
 */

namespace nt::MultigroupCodec {
    /** @brief One entry in a multigroup snapshot: (relation_name, root_hex). */
    using RelationEntry = std::pair<std::string, std::string>;

    /**
     * @brief Build a multigroup tree from a list of (name, root) entries.
     *
     * Each `Insert` advances the root through `O(log_B)` nodes. The final
     * root hash is the snapshot identifier. The list need not be pre-sorted —
     * the merkle B-tree imposes order intrinsically.
     *
     * @param store     KV backend; receives all node blobs.
     * @param relations Entries to load. Duplicates collapse to the last value.
     * @return Root node hash (empty string when `relations` is empty).
     */
    std::string Build(IStorageBackend& store, const std::vector<RelationEntry>& relations);

    /**
     * @brief Enumerate all (name, root_hex) pairs at a multigroup root.
     *
     * Pages the entire tree (offset 0, no limit). Returned entries are in
     * key-sorted order. Empty input root yields an empty list.
     */
    std::vector<RelationEntry> List(IStorageBackend& store, const std::string& root_hex);

    /**
     * @brief Insert or overwrite one (relation_name → root_hex) entry.
     *
     * Equivalent to `Merkle<std::string>::Insert` after hex-decoding the
     * payload. The caller threads the returned root hash through subsequent
     * mutations. Pass an empty `root_hex` for the prior-state argument to
     * start from an empty tree.
     */
    std::string InsertOne(IStorageBackend& store, const std::string& root_hex,
                          const std::string& relation_name, const std::string& relation_root_hex);

    /**
     * @brief Remove one relation entry from the multigroup tree.
     *
     * Returns the new root hash; empty when the tree becomes empty.
     */
    std::string RemoveOne(IStorageBackend& store, const std::string& root_hex,
                          const std::string& relation_name);

    /**
     * @brief Look up one relation's root hex by name.
     * @return Hex root, or empty string when the name is absent.
     */
    std::string Lookup(IStorageBackend& store, const std::string& root_hex,
                       const std::string& relation_name);
} // namespace nt::MultigroupCodec
