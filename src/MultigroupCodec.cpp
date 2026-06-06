#include "MultigroupCodec.h"

#include "Merkle.h"

#include <map>

namespace nt::MultigroupCodec {
    // A relation with zero tuples reports an empty merkle_root externally.
    // The merkle tree's payload type is fixed-width Hash32, so the codec
    // maps "" ↔ the all-zero hash. The collision probability with a real
    // SHA256 hitting all-zero (2^-256) is treated as unreachable.
    static nt::Hash32 encode_payload(const std::string& hex) {
        if (hex.empty())
            return nt::Hash32{};
        return nt::hex_to_bin(hex);
    }

    static std::string decode_payload(const nt::Hash32& bin) {
        static const nt::Hash32 zero{};
        if (bin == zero)
            return "";
        return nt::bin_to_hex(bin);
    }

    std::string Build(IStorageBackend& store, const std::vector<RelationEntry>& relations) {
        std::map<std::string, std::string> canonical;
        for (const auto& [name, root_hex] : relations)
            canonical[name] = root_hex;

        std::string root;
        for (const auto& [name, root_hex] : canonical)
            root = nt::Merkle<std::string>::Insert(store, root, name, encode_payload(root_hex));
        return root;
    }

    std::vector<RelationEntry> List(IStorageBackend& store, const std::string& root_hex) {
        std::vector<RelationEntry> out;
        constexpr size_t kPageSize = 1024;
        size_t offset = 0;
        while (true) {
            auto page = nt::Merkle<std::string>::Page(store, root_hex, offset, kPageSize);
            if (page.empty())
                break;
            for (auto& entry : page)
                out.emplace_back(std::move(entry.key), decode_payload(entry.payload));
            if (page.size() < kPageSize)
                break;
            offset += page.size();
        }
        return out;
    }

    std::string InsertOne(IStorageBackend& store, const std::string& root_hex,
                          const std::string& relation_name, const std::string& relation_root_hex) {
        return nt::Merkle<std::string>::Insert(store, root_hex, relation_name,
                                               encode_payload(relation_root_hex));
    }

    std::string RemoveOne(IStorageBackend& store, const std::string& root_hex,
                          const std::string& relation_name) {
        return nt::Merkle<std::string>::Remove(store, root_hex, relation_name);
    }

    std::string Lookup(IStorageBackend& store, const std::string& root_hex,
                       const std::string& relation_name) {
        auto found = nt::Merkle<std::string>::Get(store, root_hex, relation_name);
        if (!found)
            return "";
        return decode_payload(*found);
    }
} // namespace nt::MultigroupCodec
