#include "CursorManager.h"
#include "Merkle.h"
#include "ObjectManager.h"
#include "TupleCodec.h"

namespace nt {
    CursorManager::CursorManager(IStorageBackend& backend, LifecycleManager* lifecycles,
                                 ObjectManager* objects)
        : backend_(backend), lifecycles_(lifecycles), objects_(objects) {
    }

    // Finds the /system/snapshots/<H> entry that owns a handle's relation, or
    // nullptr when the relation lives outside the snapshot namespace (tests use
    // synthetic paths like {"relations", "villager"}).
    static ObjectManager::registry* find_parent_snapshot(ObjectManager& objects,
                                                         HandlerManager::handle* handle) {
        if (handle == nullptr || handle->object == nullptr || handle->object->head == nullptr)
            return nullptr;

        const auto& p = handle->object->head->path;
        if (p.size() != 5)
            return nullptr;
        if (p[0] != "system" || p[1] != "snapshots" || p[3] != "relations")
            return nullptr;

        return objects.Find({p[0], p[1], p[2]});
    }

    void CursorManager::LoadPage(cursor* c) {
        auto entries = Merkle<Hash32>::Page(backend_, c->merkle_root, c->fetch_offset, PAGE_SIZE);
        c->page.clear();
        c->page_position = 0;

        for (const auto& entry : entries) {
            auto bytes = backend_.Get(bin_to_hex(entry.payload));
            if (!bytes)
                continue;
            c->page.emplace_back(TupleCodec::Deserialize(*bytes));
        }

        c->fetch_offset += entries.size();
        if (entries.size() < PAGE_SIZE)
            c->exhausted = true;
    }

    CursorManager::cursor* CursorManager::Open(HandlerManager::handle* handle,
                                               const std::string& merkle_root) {
        if (handle == nullptr || handle->object == nullptr)
            return nullptr;

        const auto label = handle->object->head->type->label;

        auto pin_snapshot = [&](cursor* c) {
            if (lifecycles_ == nullptr || objects_ == nullptr)
                return;
            auto* snap = find_parent_snapshot(*objects_, handle);
            if (snap == nullptr)
                return;
            lifecycles_->Pin(snap);
            c->pinned_snapshot = snap;
        };

        if (label == EPHEMERAL_RELATION) {
            // Cursor opens ready for a standalone scan (no bound args, offset
            // zero) so a named ephemeral can be drained like a stored relation.
            // A JOIN probe overwrites this state anyway: the operator writes
            // args and resets the cursor before the first probe. The generator
            // is copied off the registry-owned ephemeral_object_type so Next()
            // never has to dereference the handle again.
            auto* etype = static_cast<ObjectManager::ephemeral_object_type*>(
                handle->object->head->type.get());

            auto* c = new cursor();
            c->is_ephemeral = true;
            c->generator = etype->generator;
            pin_snapshot(c);
            return c;
        }

        if (label != RELATION)
            return nullptr;

        auto* c = new cursor();
        c->merkle_root = merkle_root;
        pin_snapshot(c);

        if (merkle_root.empty()) {
            // Empty relation: valid but immediately exhausted.
            c->exhausted = true;
            return c;
        }

        LoadPage(c);
        return c;
    }

    Tuple* CursorManager::Next(cursor* c) {
        if (c == nullptr)
            return nullptr;

        if (c->page_position < c->page.size())
            return &c->page[c->page_position++];

        if (c->exhausted)
            return nullptr;

        if (c->is_ephemeral) {
            c->page = c->generator(c->args, c->fetch_offset, PAGE_SIZE);
            c->page_position = 0;
            c->fetch_offset += c->page.size();
            if (c->page.size() < PAGE_SIZE)
                c->exhausted = true;
            if (c->page.empty())
                return nullptr;
            return &c->page[c->page_position++];
        }

        LoadPage(c);
        if (c->page.empty())
            return nullptr;
        return &c->page[c->page_position++];
    }

    void CursorManager::Close(cursor* c) {
        if (c == nullptr) {
            return;
        }
        if (lifecycles_ != nullptr && c->pinned_snapshot != nullptr)
            lifecycles_->Unpin(c->pinned_snapshot);
        delete c;
    }
} // namespace nt
