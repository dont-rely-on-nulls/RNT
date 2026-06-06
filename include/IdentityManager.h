#pragma once

#include "Api.h"
#include "ObjectManager.h"

/**
 * @file IdentityManager.h
 * @brief Declares object capability checks.
 */

namespace nt {
    /**
     * @brief Checks whether an object supports identity-level operations.
     *
     * @todo Migrate to type callbacks. Once `object_type` holds `OpenProcedure`
     *       and `CloseProcedure` function pointers, CanOpen / CanClose become
     *       thin dispatchers that invoke the corresponding procedure — or this
     *       manager is absorbed into HandlerManager directly. The function pointer
     *       should be accompanied by a `const char* name` label on `object_type`
     *       so that error logs identify the type without dereferencing the pointer.
     *       See docs/reactos-ob-comparison.md §2.
     */
    class IdentityManager {
      public:
        /**
         * @brief Returns true when the object's type supports being opened.
         *
         * Currently checks that the object is non-null (stub). Should invoke
         * `object_type::OpenProcedure` once callbacks are defined.
         *
         * @param object Object to inspect.
         * @return True when the object can be opened.
         */
        const bool CanOpen(ObjectManager::registry* object);

        /**
         * @brief Returns true when the object's type supports being closed.
         *
         * Currently checks that the object is non-null (stub). Should invoke
         * `object_type::CloseProcedure` once callbacks are defined.
         *
         * @param object Object to inspect.
         * @return True when the object can be closed.
         */
        const bool CanClose(ObjectManager::registry* object);
    };
} // namespace nt
