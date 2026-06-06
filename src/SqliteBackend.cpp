#include "SqliteBackend.h"

#include <picosha2.h>
#include <stdexcept>

namespace nt {
    SqliteBackend::SqliteBackend(const std::string& path) {
        if (sqlite3_open(path.c_str(), &db_) != SQLITE_OK)
            throw std::runtime_error(sqlite3_errmsg(db_));

        const char* schema = "CREATE TABLE IF NOT EXISTS kv ("
                             "  hash  TEXT PRIMARY KEY,"
                             "  value BLOB NOT NULL"
                             ");";

        char* err = nullptr;
        if (sqlite3_exec(db_, schema, nullptr, nullptr, &err) != SQLITE_OK) {
            std::string msg(err);
            sqlite3_free(err);
            throw std::runtime_error(msg);
        }
    }

    SqliteBackend::~SqliteBackend() {
        sqlite3_close(db_);
    }

    std::string SqliteBackend::Put(std::vector<uint8_t> value) {
        const std::string hash = picosha2::hash256_hex_string(value.begin(), value.end());

        sqlite3_stmt* stmt = nullptr;
        sqlite3_prepare_v2(db_, "INSERT OR IGNORE INTO kv (hash, value) VALUES (?, ?)", -1, &stmt,
                           nullptr);
        sqlite3_bind_text(stmt, 1, hash.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_blob(stmt, 2, value.data(), static_cast<int>(value.size()), SQLITE_TRANSIENT);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
        return hash;
    }

    std::optional<std::vector<uint8_t>> SqliteBackend::Get(const std::string& hash) {
        sqlite3_stmt* stmt = nullptr;
        sqlite3_prepare_v2(db_, "SELECT value FROM kv WHERE hash = ?", -1, &stmt, nullptr);
        sqlite3_bind_text(stmt, 1, hash.c_str(), -1, SQLITE_TRANSIENT);

        std::optional<std::vector<uint8_t>> result;
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            const auto* blob = static_cast<const uint8_t*>(sqlite3_column_blob(stmt, 0));
            int size = sqlite3_column_bytes(stmt, 0);
            result = std::vector<uint8_t>(blob, blob + size);
        }
        sqlite3_finalize(stmt);
        return result;
    }
} // namespace nt
