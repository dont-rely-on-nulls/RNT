#include "TupleCodec.h"

#include <picosha2.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <numeric>

namespace nt::TupleCodec {
    static std::vector<Attribute> Sorted(std::vector<Attribute> attrs) {
        std::sort(attrs.begin(), attrs.end(),
                  [](const Attribute& a, const Attribute& b) { return a.name < b.name; });
        return attrs;
    }

    std::string Hash(const std::vector<Attribute>& attrs) {
        auto bytes = Serialize(attrs);
        return picosha2::hash256_hex_string(bytes.begin(), bytes.end());
    }

    std::vector<uint8_t> Serialize(const std::vector<Attribute>& attrs) {
        // Format: [uint32_le name_len][name][uint32_le value_len][value] ...
        // Attributes are stored in sorted name order for determinism.
        std::vector<uint8_t> out;
        auto write_u32 = [&](uint32_t n) {
            out.push_back(static_cast<uint8_t>(n));
            out.push_back(static_cast<uint8_t>(n >> 8));
            out.push_back(static_cast<uint8_t>(n >> 16));
            out.push_back(static_cast<uint8_t>(n >> 24));
        };

        for (const auto& a : Sorted({attrs.begin(), attrs.end()})) {
            write_u32(static_cast<uint32_t>(a.name.size()));
            out.insert(out.end(), a.name.begin(), a.name.end());
            write_u32(static_cast<uint32_t>(a.value.size()));
            out.insert(out.end(), a.value.begin(), a.value.end());
        }
        return out;
    }

    std::vector<Attribute> Deserialize(const std::vector<uint8_t>& bytes) {
        auto read_u32 = [&](size_t pos) -> uint32_t {
            return static_cast<uint32_t>(bytes[pos]) |
                   (static_cast<uint32_t>(bytes[pos + 1]) << 8) |
                   (static_cast<uint32_t>(bytes[pos + 2]) << 16) |
                   (static_cast<uint32_t>(bytes[pos + 3]) << 24);
        };

        std::vector<Attribute> result;
        size_t pos = 0;
        while (pos + 8 <= bytes.size()) {
            uint32_t name_len = read_u32(pos);
            pos += 4;
            std::string name(reinterpret_cast<const char*>(bytes.data() + pos), name_len);
            pos += name_len;

            uint32_t value_len = read_u32(pos);
            pos += 4;
            std::string value(reinterpret_cast<const char*>(bytes.data() + pos), value_len);
            pos += value_len;

            result.push_back({std::move(name), std::move(value)});
        }
        return result;
    }
} // namespace nt::TupleCodec
