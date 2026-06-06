#include "IdentityManager.h"

namespace nt {
    const bool IdentityManager::CanOpen(ObjectManager::registry* object) {
        return object != nullptr;
    }

    const bool IdentityManager::CanClose(ObjectManager::registry* object) {
        return object != nullptr;
    }
} // namespace nt
