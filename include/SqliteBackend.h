#pragma once

#include "Api.h"
#include "IStorageBackend.h"

#include <sqlite3.h>
#include <string>
#include <vector>

/**
 * @file SqliteBackend.h
 * @brief IStorageBackend implementation backed by an in-process SQLite database.
 *
 * SQLite schema:
 *
 *   kv(hash TEXT PRIMARY KEY, value BLOB NOT NULL)
 *     — content-addressed store; key is the SHA256 hex digest of value.
 *
 * Relation membership is tracked by the Merkle B-tree maintained in-process.
 * The former relation_index table has been removed; tuple hashes are looked up
 * via Merkle::Page which reads only the KV store.
 */

namespace nt {
    class SqliteBackend : public IStorageBackend {
      public:
        /**
         * @brief Opens (or creates) a SQLite database at @p path.
         * @param path File path, or ":memory:" for an in-process database.
         * @throws std::runtime_error if the database cannot be opened.
         */
        explicit SqliteBackend(const std::string& path = ":memory:");
        ~SqliteBackend() override;

        std::string Put(std::vector<uint8_t> value) override;
        std::optional<std::vector<uint8_t>> Get(const std::string& hash) override;

      private:
        sqlite3* db_ = nullptr;
    };
} // namespace nt
