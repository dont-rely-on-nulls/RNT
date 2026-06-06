#include "PermissionsManager.h"

namespace nt {
    std::set<AUTH_CLAIM> PermissionsManager::Firewall(AUTH_METHOD method) {
        return {};
    }

    const bool PermissionsManager::Access(const ObjectManager::registry* object,
                                          const void* connection_context) {
        // Checks the security descriptor on the head of the object we find in the
        // ObjectManager::registry Then additionally check other metadata yet to be defined in the
        // connection_context, like user group, policy, etc. Yet to decide if this should be
        // summoned at every attempt to get ahold of an object, that might produce significant
        // overhead. How can we solve this?
        return object != nullptr;
    }
} // namespace nt
