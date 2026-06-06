#include "HandlerManager.h"

#include "IdentityManager.h"
#include "LifecycleManager.h"
#include "NamespaceReferenceManager.h"
#include "PermissionsManager.h"

namespace nt {
    void HandlerManager::DeallocateHandle(struct handle* handle) {
        delete handle;
    }

    HandlerManager::HandlerManager(ObjectManager& objects, PermissionsManager& permissions,
                                   IdentityManager& identities, LifecycleManager& lifecycles,
                                   NamespaceReferenceManager& references)
        : objects_(objects), permissions_(permissions), identities_(identities),
          lifecycles_(lifecycles), references_(references) {
    }

    struct HandlerManager::handle* HandlerManager::Open(std::vector<std::string> object_path,
                                                        void* connection_context) {
        const auto resolved = references_.Resolve(std::move(object_path));
        ObjectManager::registry* retrieved_object = objects_.Find(resolved);
        if (permissions_.Access(retrieved_object, (const void*)connection_context) &&
            identities_.CanOpen(retrieved_object) && lifecycles_.Contention(retrieved_object)) {
            // Starts monitoring this guy
            lifecycles_.Monitor(retrieved_object);
            return new handle{retrieved_object, connection_context}; // Return a successful handle
        } else {
            // Return something more algebraic instead of null or an int
            return nullptr;
        };
    }

    bool HandlerManager::Close(struct handle* handle) {
        if (handle == nullptr) {
            return false;
        }
        // Somehow grab the object pointer and connection (maybe drop it...) from the handle
        ObjectManager::registry* object = handle->object;
        void* connection_context = handle->connection_context;
        // Checking for permissions here may be relevant.
        // What if we have a handle but no permission? Spooky
        if (permissions_.Access(object, connection_context) && identities_.CanClose(object)
            // TODO: I think that in this case we do not need to worry about contention.
            // But be careful to evaluate this scenario later.
            //&& lifecycles_.Contention(object)
        ) {
            // Stops monitoring this guy
            lifecycles_.Unmonitor(object);
            DeallocateHandle(handle);
            return true; // Return a successful handle
        } else {
            // Return something more algebraic instead of null or an int.
            // It's kinda bad to not even report what went wrong.
            return false;
        };
    }
} // namespace nt
