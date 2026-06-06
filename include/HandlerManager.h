#pragma once

#include "Api.h"
#include "ObjectManager.h"
#include "Types.h"

#include <set>
#include <string>
#include <vector>

/**
 * @file HandlerManager.h
 * @brief Declares handle allocation and release for authorized object access.
 */

namespace nt {
    class IdentityManager;
    class LifecycleManager;
    class NamespaceReferenceManager;
    class PermissionsManager;

    /** @brief Opens and closes authorized handles to registry objects. */
    class HandlerManager {
      public:
        /**
         * @brief Constructs a HandlerManager with shared runtime dependencies.
         *
         * All managers are injected so that state (registry entries, lifecycle
         * counters, permission policy) persists across calls rather than being
         * rebuilt per open/close.
         */
        HandlerManager(ObjectManager& objects, PermissionsManager& permissions,
                       IdentityManager& identities, LifecycleManager& lifecycles,
                       NamespaceReferenceManager& references);

        /**
         * @brief Represents authorized access to an object in the registry.
         *
         * The access mask is evaluated once during Open and cached here for the
         * lifetime of the handle. Subsequent operations check `granted_access`
         * rather than re-evaluating the security descriptor on every call. This
         * resolves the performance question in PermissionsManager about when to
         * check permissions.
         *
         * Because storage is append-only, a WRITE claim does not mean mutating an
         * existing tuple in-place. It means the session is authorized to commit a
         * new snapshot version of the relation. Two sessions holding WRITE handles
         * on the same relation always produce independent snapshots — there is no
         * data-level conflict.
         *
         * @todo Populate `granted_access` inside HandlerManager::Open from
         *       PermissionsManager::Firewall / Access. See docs/reactos-ob-comparison.md §4.
         */
        struct handle {
            /** Object referenced by this handle. */
            ObjectManager::registry* object = nullptr;
            /** Connection metadata associated with the authorized access. */
            void* connection_context = nullptr;
            /**
             * Access claims granted to this handle at open time.
             * Cached here so that per-operation checks read from the handle
             * rather than re-evaluating the security descriptor.
             * @todo Populate in HandlerManager::Open.
             */
            std::set<AUTH_CLAIM> granted_access;
        };

        /**
         * @brief Releases a handle allocation.
         * @param handle Handle to release.
         */
        void DeallocateHandle(struct handle* handle);

        /**
         * @brief Opens an object by path for a connection.
         * @param object_path Logical object path.
         * @param connection_context Connection metadata for the caller.
         * @return A valid handle pointer on success, or nullptr on failure.
         */
        struct handle* Open(std::vector<std::string> object_path, void* connection_context);

        /**
         * @brief Closes a previously opened handle.
         * @param handle Handle to close.
         * @return True when the handle was closed successfully.
         */
        bool Close(struct handle* handle);

      private:
        ObjectManager& objects_;
        PermissionsManager& permissions_;
        IdentityManager& identities_;
        LifecycleManager& lifecycles_;
        NamespaceReferenceManager& references_;
    };
} // namespace nt
