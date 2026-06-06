#include "ObjectManager.h"

namespace nt {
    void ObjectManager::Register(std::vector<std::string> path, std::unique_ptr<IObject> object,
                                 std::unique_ptr<object_type> type) {
        auto head = std::make_unique<registry_head>();
        head->reference_count = 0;
        head->handle_count = 0;
        head->path = std::move(path);
        head->type = std::move(type);

        auto entry = std::make_unique<registry>();
        entry->head = std::move(head);
        entry->object = std::move(object);
        entry->next = std::move(entries);
        entries = std::move(entry);
    }

    ObjectManager::registry* ObjectManager::Find(const std::vector<std::string> object_path) {
        registry* current = entries.get();
        while (current != nullptr) {
            if (current->head->path == object_path)
                return current;
            current = current->next.get();
        }
        return nullptr;
    }

    bool ObjectManager::Unregister(const std::vector<std::string>& object_path) {
        std::unique_ptr<registry>* slot = &entries;
        while (slot->get() != nullptr) {
            if ((*slot)->head->path == object_path) {
                *slot = std::move((*slot)->next);
                return true;
            }
            slot = &(*slot)->next;
        }
        return false;
    }
} // namespace nt
