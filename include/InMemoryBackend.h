#pragma once

#include "Api.h"
#include "IStorageBackend.h"

#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

/**
 * @file InMemoryBackend.h
 * @brief In-process KV storage backend backed by an unordered_map.
 *
 * Intended for unit tests where SQLite is not appropriate.  Data does not
 * survive process exit and is not thread-safe.
 *
 * Relation membership is tracked by the Merkle class, not this backend.
 */

namespace nt {
    class InMemoryBackend : public IStorageBackend {
      public:
        std::string Put(std::vector<uint8_t> value) override;
        std::optional<std::vector<uint8_t>> Get(const std::string& hash) override;
        std::optional<std::function<void(void)>> RetrieveCapability(BackendCapabilities) override {return {};};

      private:
        std::unordered_map<std::string, std::vector<uint8_t>> kv_;
    };
} // namespace nt
