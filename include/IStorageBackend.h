#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

/**
 * @file IStorageBackend.h
 * @brief Abstract KV storage backend consumed by CursorManager and Merkle.
 *
 * Storage is strictly content-addressed: every value is stored under its
 * SHA256 hex digest.  Relation membership (which tuple hashes belong to a
 * given relation) is now tracked via the Merkle B-tree maintained by the
 * Merkle class, not by this interface.  Only Put and Get are required.
 */

namespace nt {
    /**
     * @interface IStorageBackend
     * @brief Contract between CursorManager / Merkle and a physical storage engine.
     *
     * Two primitives are sufficient:
     *   - Put: store bytes, get back the content-address (SHA256 hex).
     *   - Get: retrieve bytes by content-address.
     *
     * Both are idempotent.  The Merkle class stores node blobs via Put/Get and
     * maintains insertion-order-independent relation membership on top of these
     * two primitives.
     */
    class IStorageBackend {
      public:
        virtual ~IStorageBackend() = default;

        /**
         * @brief Stores a serialized value and returns its SHA256 hex hash.
         *
         * Idempotent: storing the same bytes twice does not create a duplicate.
         * The returned hash is the only valid key for subsequent Get calls.
         */
        virtual std::string Put(std::vector<uint8_t> value) = 0;

        /**
         * @brief Retrieves bytes by their SHA256 hex hash.
         * @return The stored bytes, or std::nullopt when the hash is unknown.
         */
        virtual std::optional<std::vector<uint8_t>> Get(const std::string& hash) = 0;
    };
} // namespace nt
