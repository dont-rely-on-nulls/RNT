#include "InMemoryBackend.h"
#include "IStorageBackend.h"

#include <optional>
#include <picosha2.h>

namespace nt {
    std::string InMemoryBackend::Put(std::vector<uint8_t> value) {
        const std::string hash = picosha2::hash256_hex_string(value.begin(), value.end());
        kv_.emplace(hash, std::move(value));
        return hash;
    }

    std::optional<std::vector<uint8_t>> InMemoryBackend::Get(const std::string& hash) {
        auto it = kv_.find(hash);
        if (it == kv_.end())
            return std::nullopt;
        return it->second;
    }

    std::optional<std::function<void(void)>> RetrieveCapability(BackendCapabilities _) {
      return {};
    }
} // namespace nt
