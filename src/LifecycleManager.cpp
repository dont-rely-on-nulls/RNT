#include "LifecycleManager.h"

#include "EphemeralRelation.h"
#include "Merkle.h"
#include "Types.h"

#include <vector>

namespace nt {
    LifecycleManager::LifecycleManager(ObjectManager& objects, IStorageBackend& storage)
        : objects_(objects), storage_(storage) {
    }

    void LifecycleManager::Monitor(ObjectManager::registry* object) {
        if (object != nullptr)
            ++object->head->handle_count;
    }

    void LifecycleManager::Unmonitor(ObjectManager::registry* object) {
        if (object == nullptr || object->head->handle_count == 0)
            return;
        --object->head->handle_count;
        TryCollect(object);
    }

    void LifecycleManager::Pin(ObjectManager::registry* object) {
        if (object != nullptr)
            ++object->head->reference_count;
    }

    void LifecycleManager::Unpin(ObjectManager::registry* object) {
        if (object == nullptr || object->head->reference_count == 0)
            return;
        --object->head->reference_count;
        TryCollect(object);
    }

    bool LifecycleManager::IsEligibleForGC(ObjectManager::registry* object) const {
        if (object == nullptr || object->head == nullptr)
            return false;
        return object->head->handle_count == 0 && object->head->reference_count == 0;
    }

    const bool LifecycleManager::Contention(ObjectManager::registry* object) {
        return object != nullptr;
    }

    bool LifecycleManager::Collect(ObjectManager::registry* object) {
        if (!IsEligibleForGC(object))
            return false;
        // Named-lifetime types (BRANCH / SESSION) never auto-collect; TryCollect
        // would no-op on them, so return false rather than report a collection.
        if (object->head->type != nullptr) {
            const auto label = object->head->type->label;
            if (label == BRANCH || label == SESSION)
                return false;
        }
        TryCollect(object);
        return true;
    }

    void LifecycleManager::TryCollect(ObjectManager::registry* object) {
        if (!IsEligibleForGC(object))
            return;
        if (object->head == nullptr || object->head->type == nullptr)
            return;

        // Named-lifetime types are managed explicitly and must not auto-collect:
        //   BRANCH  — named branches persist until a future explicit-delete API
        //             tears them down. Their counters going to zero just means
        //             nobody currently holds them open.
        //   SESSION — rnt_session_close is the sole removal path.
        // Everything else (MULTIGROUP, BRANCH_TREE, RELATION,
        // EPHEMERAL_RELATION, TRANSACTION) is purely structurally referenced
        // and is GC-eligible by counters alone.
        const auto label = object->head->type->label;
        if (label == BRANCH || label == SESSION)
            return;

        if (label == MULTIGROUP)
            CascadeMultigroup(object);
        if (label == BRANCH_TREE)
            CascadeBranchTree(object);
        if (label == EPHEMERAL_RELATION)
            CascadeEphemeral(object);

        objects_.Unregister(object->head->path);
    }

    void LifecycleManager::CascadeMultigroup(ObjectManager::registry* multigroup) {
        if (multigroup == nullptr || multigroup->head == nullptr)
            return;
        const auto& mg_path = multigroup->head->path;
        if (mg_path.size() < 3)
            return;

        // /system/snapshots/<hash>/relations/<n> entries are the relation
        // children pinned by this multigroup. Collect first, mutate after —
        // Unpin can Unregister the entry we're standing on if its counters
        // were already zero, and iteration must outlive that mutation.
        std::vector<ObjectManager::registry*> children;
        for (auto* cur = objects_.entries.get(); cur != nullptr; cur = cur->next.get()) {
            const auto& p = cur->head->path;
            if (p.size() != mg_path.size() + 2)
                continue;

            bool prefix_match = true;
            for (size_t i = 0; i < mg_path.size(); ++i)
                if (p[i] != mg_path[i]) {
                    prefix_match = false;
                    break;
                }
            if (!prefix_match)
                continue;
            if (p[mg_path.size()] != "relations")
                continue;

            children.push_back(cur);
        }

        for (auto* child : children)
            Unpin(child);
    }

    void LifecycleManager::CascadeBranchTree(ObjectManager::registry* branch_tree) {
        if (branch_tree == nullptr || branch_tree->head == nullptr)
            return;

        auto* bt = dynamic_cast<ObjectManager::BranchTree*>(branch_tree->object.get());
        if (bt == nullptr || bt->merkle_root.empty())
            return;

        // Page through the (mg_name, mg_hash) tree and collect each referenced
        // multigroup before unpinning. Decoupling iteration from mutation
        // keeps us safe against Unpin cascading further GC under our feet.
        std::vector<ObjectManager::registry*> mgs;
        constexpr size_t kPageSize = 1024;
        size_t offset = 0;
        while (true) {
            auto page = Merkle<std::string>::Page(storage_, bt->merkle_root, offset, kPageSize);
            if (page.empty())
                break;
            for (const auto& entry : page) {
                static const Hash32 zero{};
                if (entry.payload == zero)
                    continue;
                const std::string mg_hash = bin_to_hex(entry.payload);
                auto* mg_entry = objects_.Find({"system", "snapshots", mg_hash});
                if (mg_entry)
                    mgs.push_back(mg_entry);
            }
            if (page.size() < kPageSize)
                break;
            offset += page.size();
        }

        for (auto* mg : mgs)
            Unpin(mg);
    }

    void LifecycleManager::CascadeEphemeral(ObjectManager::registry* ephemeral) {
        if (ephemeral == nullptr || ephemeral->object == nullptr)
            return;
        auto* er = dynamic_cast<ObjectManager::EphemeralRelation*>(ephemeral->object.get());
        if (er == nullptr)
            return;

        // Resolve each dependency path and collect before mutating: Unpin can
        // cascade further GC, and iteration must outlive that mutation.
        std::vector<ObjectManager::registry*> deps;
        for (const auto& dep : er->dependencies) {
            const auto parts = Ephemeral::SplitPath(dep);
            if (parts.empty())
                continue;
            auto* entry = objects_.Find(parts);
            if (entry != nullptr)
                deps.push_back(entry);
        }

        for (auto* dep : deps)
            Unpin(dep);
    }
} // namespace nt
