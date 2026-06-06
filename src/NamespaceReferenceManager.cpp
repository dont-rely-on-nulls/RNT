#include "NamespaceReferenceManager.h"

#include "Merkle.h"

namespace nt {
    NamespaceReferenceManager::NamespaceReferenceManager(ObjectManager& objects,
                                                         IStorageBackend& storage)
        : objects_(objects), storage_(storage) {
    }

    // Resolves the multigroup hash that `mg_name` currently maps to inside the
    // branch-tree rooted at `branch_tree_root`. Returns the empty string when
    // the branch is unborn (empty root) or the multigroup is absent.
    static std::string lookup_mg_hash(IStorageBackend& storage, const std::string& branch_tree_root,
                                      const std::string& mg_name) {
        if (branch_tree_root.empty())
            return "";
        auto found = Merkle<std::string>::Get(storage, branch_tree_root, mg_name);
        if (!found)
            return "";
        // All-zero payload = "no snapshot bound" sentinel matching MultigroupCodec.
        static const Hash32 zero{};
        if (*found == zero)
            return "";
        return bin_to_hex(*found);
    }

    std::vector<std::string>
    NamespaceReferenceManager::Resolve(std::vector<std::string> path) const {
        constexpr int kMaxReparseDepth = 30;

        for (int depth = 0; depth < kMaxReparseDepth; ++depth) {
            // /system/sessions/<X>/branches/<name>/multigroups/<mg>/<sub>...
            // — per-session override takes precedence; absent override falls
            // back to the global branch. Requires at minimum the literal
            // "multigroups" qualifier and an mg name.
            if (path.size() > 6 && path[0] == "system" && path[1] == "sessions" &&
                path[3] == "branches" && path[5] == "multigroups") {
                const std::vector<std::string> session_path{"system", "sessions", path[2]};
                auto* session_entry = objects_.Find(session_path);

                std::string branch_tree_root;
                if (session_entry && session_entry->object) {
                    auto* session =
                        dynamic_cast<ObjectManager::Session*>(session_entry->object.get());
                    if (session) {
                        auto it = session->branch_overrides.find(path[4]);
                        if (it != session->branch_overrides.end())
                            branch_tree_root = it->second;
                    }
                }

                // No session-level override — defer to the global branch's HEAD.
                if (branch_tree_root.empty()) {
                    const std::vector<std::string> branch_path{"system", "branches", path[4]};
                    auto* bentry = objects_.Find(branch_path);
                    if (bentry && bentry->object) {
                        auto* branch = dynamic_cast<ObjectManager::Branch*>(bentry->object.get());
                        if (branch)
                            branch_tree_root = branch->target_hash;
                    }
                }

                const std::string mg_hash = lookup_mg_hash(storage_, branch_tree_root, path[6]);
                if (mg_hash.empty())
                    return path;

                std::vector<std::string> rewritten{"system", "snapshots", mg_hash};
                for (size_t i = 7; i < path.size(); ++i)
                    rewritten.push_back(path[i]);

                path = std::move(rewritten);
                continue;
            }

            // /system/branches/<name>/multigroups/<mg>/<sub>... →
            //   /system/snapshots/<mg_hash>/<sub>...
            // Requires the literal "multigroups" qualifier and an mg name. A
            // bare /system/branches/<name> path opens the branch object itself
            // and is returned unchanged.
            if (path.size() > 4 && path[0] == "system" && path[1] == "branches" &&
                path[3] == "multigroups") {
                const std::vector<std::string> branch_path{"system", "branches", path[2]};
                auto* entry = objects_.Find(branch_path);
                if (!entry || !entry->object)
                    return path;

                auto* branch = dynamic_cast<ObjectManager::Branch*>(entry->object.get());
                if (!branch)
                    return path;

                const std::string mg_hash = lookup_mg_hash(storage_, branch->target_hash, path[4]);
                if (mg_hash.empty())
                    return path;

                std::vector<std::string> rewritten{"system", "snapshots", mg_hash};
                for (size_t i = 5; i < path.size(); ++i)
                    rewritten.push_back(path[i]);

                path = std::move(rewritten);
                continue;
            }

            return path;
        }

        // Cycle guard tripped — surface as a lookup miss.
        return {};
    }
} // namespace nt
