#include "EphemeralRelation.h"

#include "Types.h"

#include <picosha2.h>

#include <algorithm>
#include <memory>

namespace nt::Ephemeral {
    namespace {
        // Object-type descriptor for an EPHEMERAL_RELATION. Ephemeral relations
        // are not durable (disposable=true) and never contend (readers compose
        // generators independently). The generator and cardinality live on the
        // descriptor; the cursor layer copies the generator out at Open time.
        std::unique_ptr<ObjectManager::object_type>
        make_type(ObjectManager::ephemeral_object_type::Cardinality cardinality,
                  ObjectManager::ephemeral_object_type::Generator generator) {
            auto t = std::make_unique<ObjectManager::ephemeral_object_type>();
            t->label = EPHEMERAL_RELATION;
            t->disposable = true;
            t->methods = {OPEN, CLOSE};
            t->exclusive = false;
            t->cardinality = cardinality;
            t->generator = std::move(generator);
            return t;
        }

        // Reads the merkle_root off a registry entry whose object is a stored or
        // ephemeral relation. Empty string for anything else (or missing root).
        std::string entry_root(ObjectManager::registry* entry) {
            if (entry == nullptr || entry->object == nullptr)
                return {};
            if (auto* r = dynamic_cast<ObjectManager::Relation*>(entry->object.get()))
                return r->merkle_root;
            if (auto* e = dynamic_cast<ObjectManager::EphemeralRelation*>(entry->object.get()))
                return e->merkle_root;
            return {};
        }
    } // namespace

    std::vector<std::string> SplitPath(const std::string& path) {
        std::vector<std::string> parts;
        std::string seg;
        for (char c : path) {
            if (c == '/') {
                if (!seg.empty())
                    parts.push_back(seg);
                seg.clear();
            } else {
                seg.push_back(c);
            }
        }
        if (!seg.empty())
            parts.push_back(seg);
        return parts;
    }

    std::string ComposeRoot(const std::string& generator_identity,
                            const std::vector<std::pair<std::string, std::string>>& schema,
                            const std::vector<std::string>& base_roots) {
        // Sort schema and base roots so input order does not change the digest.
        std::vector<std::pair<std::string, std::string>> sorted_schema = schema;
        std::sort(sorted_schema.begin(), sorted_schema.end());
        std::vector<std::string> sorted_roots = base_roots;
        std::sort(sorted_roots.begin(), sorted_roots.end());

        std::string buf;
        buf += generator_identity;
        buf.push_back('\0');
        // NUL-separate each field so distinct (name, type) splits cannot
        // serialize to the same bytes, then a lone NUL to close the schema.
        for (const auto& [name, type] : sorted_schema) {
            buf += name;
            buf.push_back('\0');
            buf += type;
            buf.push_back('\0');
        }
        buf.push_back('\0');
        for (const auto& root : sorted_roots) {
            buf += root;
            buf.push_back('\n');
        }
        return picosha2::hash256_hex_string(buf.begin(), buf.end());
    }

    ObjectManager::registry* Register(
        ObjectManager& objects, LifecycleManager& lifecycles, const std::string& session_hash,
        Tier tier, const std::string& name,
        ObjectManager::ephemeral_object_type::Generator generator,
        ObjectManager::ephemeral_object_type::Cardinality cardinality,
        const std::string& generator_identity,
        const std::vector<std::pair<std::string, std::string>>& schema,
        const std::vector<std::string>& dependencies) {
        if (session_hash.empty())
            return nullptr;
        if (tier == Tier::Named && name.empty())
            return nullptr;

        // Resolve dependencies up front: read their current roots for the
        // identity hash and keep the entries to pin after registration. An
        // unresolvable dependency fails the registration; skipping it would
        // store a path that was never pinned, and CascadeEphemeral would later
        // Unpin a hold it never took.
        std::vector<ObjectManager::registry*> dep_entries;
        std::vector<std::string> base_roots;
        dep_entries.reserve(dependencies.size());
        base_roots.reserve(dependencies.size());
        for (const auto& dep : dependencies) {
            auto* entry = objects.Find(SplitPath(dep));
            if (entry == nullptr)
                return nullptr;
            dep_entries.push_back(entry);
            base_roots.push_back(entry_root(entry));
        }

        const std::string root = ComposeRoot(generator_identity, schema, base_roots);
        const std::string subdir = (tier == Tier::Named) ? "ephemeral" : "scratch";
        const std::string leaf = (tier == Tier::Named) ? name : root;
        const std::vector<std::string> path = {"system", "sessions", session_hash, subdir, leaf};

        // Idempotent: an identical scratch result, or a live named binding,
        // reuses the existing entry without double-pinning.
        if (auto* existing = objects.Find(path))
            return existing;

        auto er = std::make_unique<ObjectManager::EphemeralRelation>();
        er->merkle_root = root;
        er->dependencies = dependencies;
        objects.Register(path, std::move(er), make_type(cardinality, std::move(generator)));

        auto* entry = objects.Find(path);
        if (entry == nullptr)
            return nullptr;

        // Structural pins on the base relations: released by
        // LifecycleManager::CascadeEphemeral when this entry is collected.
        for (auto* dep : dep_entries)
            lifecycles.Pin(dep);

        // Tier policy: a named ephemeral is owned by its session and outlives
        // its cursor; a scratch intermediate is owned by nobody and dies by
        // counters with its cursor.
        if (tier == Tier::Named)
            lifecycles.Pin(entry);

        return entry;
    }

    std::size_t ReleaseSession(ObjectManager& objects, LifecycleManager& lifecycles,
                               const std::string& session_hash) {
        const std::vector<std::string> named_prefix = {"system", "sessions", session_hash,
                                                        "ephemeral"};
        const std::vector<std::string> scratch_prefix = {"system", "sessions", session_hash,
                                                          "scratch"};

        auto is_child = [](const std::vector<std::string>& path,
                           const std::vector<std::string>& prefix) {
            if (path.size() != prefix.size() + 1)
                return false;
            for (std::size_t i = 0; i < prefix.size(); ++i)
                if (path[i] != prefix[i])
                    return false;
            return true;
        };

        // Collect targets before mutating: Unpin / Collect splice entries out of
        // the same list we are walking.
        std::vector<ObjectManager::registry*> named;
        std::vector<ObjectManager::registry*> scratch;
        for (auto* cur = objects.entries.get(); cur != nullptr; cur = cur->next.get()) {
            if (cur->head == nullptr)
                continue;
            const auto& p = cur->head->path;
            if (is_child(p, named_prefix))
                named.push_back(cur);
            else if (is_child(p, scratch_prefix))
                scratch.push_back(cur);
        }

        std::size_t released = 0;
        // Named: drop the session-ownership pin; collects if nothing else holds it.
        for (auto* entry : named) {
            const uint32_t before = entry->head->reference_count;
            lifecycles.Unpin(entry);
            if (before > 0)
                ++released;
        }
        // Scratch: never session-pinned; collect any stragglers whose cursor closed.
        for (auto* entry : scratch)
            if (lifecycles.Collect(entry))
                ++released;

        return released;
    }
} // namespace nt::Ephemeral
