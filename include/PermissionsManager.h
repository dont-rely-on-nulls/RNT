#pragma once

#include "Api.h"
#include "ObjectManager.h"
#include "Types.h"

#include <set>

/**
 * @file PermissionsManager.h
 * @brief Declares authentication and object-access checks.
 */

namespace nt {
    /**
     * @class Capability-based permission manager
     * @brief Evaluates connection claims and object permissions.
     *
     * Permission checks are intentionally separated from lookup. The object
     * manager can retrieve a candidate object, while this manager decides
     * whether the caller is allowed to use it.
     *
     * Permissions are strictly capability-based and must be explicitly granted.
     * There is no implicit flow of access rights from a parent namespace entry to
     * its children (no SD inheritance). A caller who holds READ on a multigroup
     * does not thereby hold READ on its constituent relations — that is a separate,
     * explicit capability.
     *
     * @todo Define a security_descriptor structure. Store instances in a shared,
     *       content-addressed cache (keyed by descriptor content, not by namespace
     *       ancestry) so that identical ACLs are not duplicated across relations.
     *       See docs/reactos-ob-comparison.md §5 and §7.
     *
     * @todo Cache the result of Access() in HandlerManager::handle::granted_access
     *       at open time. Per-operation checks should then read from the handle
     *       rather than re-evaluating the descriptor on every call.
     *       See docs/reactos-ob-comparison.md §4.
     */
    class PermissionsManager {
      public:
        /**
         * @brief Validates a connection during login.
         * @param method Authentication method used by the connection.
         * @return Claims granted to the authenticated connection.
         */
        std::set<AUTH_CLAIM> Firewall(AUTH_METHOD method);

        /**
         * @brief Validates permission to an object.
         *
         * Checks the security descriptor on the head of the object found in
         * ObjectManager::registry. It should also check connection metadata
         * that is still to be defined, such as user group and policy.
         *
         * It is still undecided whether this should run on every attempt to get
         * hold of an object, since that might produce significant overhead.
         *
         * Note that the permissions systems also rely on objects with capabilities,
         * so imagining the case an ephemeral relation is created based on
         * 3 other stored relations, while you can access the ephemeral relation,
         * you cannot directly access the other 3 relations. You need explicit
         * permission to create a handle on the others.
         *
         * Here's an example tree:
         * /system
         *     /multigroups
         *         /coffee_shop
         *             /relations
         *                 /user {type : stored}
         *                 /order {type : stored}
         *                 /user_and_order {type : ephemeral; deps =
         * [/system/multigroups/coffee_shop/relations/users,
         * /system/multigroups/coffee_shop/relations/orders]} /users /peter /permissions
         *                 /multigroups/coffee_shop/relations/user_and_order {descriptor : [read]}
         *         /paul
         *             /permissions
         *                 /multigroups/coffee_shop/relations/user {descriptor : [write, read]}
         *
         * Meaning that `peter` has access to read the `user_and_order` ephemeral
         * relation, but cannot open a handle on `user` and `order`.
         *
         * @param object Object being accessed.
         * @param connection_context Connection metadata for the caller.
         * @return True when access is allowed.
         */
        const bool Access(const ObjectManager::registry* object, const void* connection_context);
    };
} // namespace nt
