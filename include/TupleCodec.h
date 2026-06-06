#pragma once

#include "Types.h"

#include <cstdint>
#include <string>
#include <vector>

/**
 * @file TupleCodec.h
 * @brief Content-addressing utilities for tuples.
 *
 * Mirrors Sakura's hashing.ml and physical.ml:
 *   - Hash()      ≈ hash_tuple: deterministic SHA256 over sorted attribute content
 *   - Serialize() ≈ Marshal.to_bytes: raw bytes stored as the KV value
 *   - Deserialize() ≈ Marshal.from_bytes: reconstruct attributes from raw bytes
 *
 * The hash input format is:
 *   "path_seg1/path_seg2/..|name1:value1;name2:value2;"
 * where attributes are sorted by name for determinism.
 *
 * The serialization format is a sequence of length-prefixed UTF-8 pairs:
 *   [uint32_le name_len][name bytes][uint32_le value_len][value bytes] ...
 */

namespace nt::TupleCodec {
    /**
     * @brief Computes the SHA256 hex digest of the serialized tuple.
     *
     * Equivalent to SHA256(Serialize(attrs)), so the value returned here
     * matches the key returned by IStorageBackend::Put(Serialize(attrs)).
     *
     * @param attrs Attribute set. Need not be pre-sorted.
     * @return 64-character lowercase hex string.
     */
    std::string Hash(const std::vector<Attribute>& attrs);

    /**
     * @brief Serializes a tuple's attributes to raw bytes for KV storage.
     * @param attrs Attribute set. Need not be pre-sorted.
     * @return Serialized bytes.
     */
    std::vector<uint8_t> Serialize(const std::vector<Attribute>& attrs);

    /**
     * @brief Reconstructs attributes from the bytes returned by Serialize().
     * @param bytes Bytes produced by Serialize().
     * @return Reconstructed attribute list in serialization order.
     */
    std::vector<Attribute> Deserialize(const std::vector<uint8_t>& bytes);
} // namespace nt::TupleCodec
