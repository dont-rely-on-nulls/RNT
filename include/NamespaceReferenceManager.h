#pragma once

#include "Api.h"
#include "IStorageBackend.h"
#include "ObjectManager.h"

#include <string>
#include <vector>

/**
 * @file NamespaceReferenceManager.h
 * @brief Declares logical reference mapping and namespace isolation.
 */

namespace nt {
    /**
     * @class NamespaceReferenceManager
     * @brief Handles the logical mapping and isolation of human-readable references.
     *
     * This manager is the reparse layer of the namespace. Its design mirrors the
     * ReactOS ParseProcedure / STATUS_REPARSE mechanism: a namespace entry whose
     * type carries a ParseProcedure can redirect name resolution to a different
     * path, allowing branch references and ephemeral relations to appear as
     * first-class objects in the namespace without exposing their physical
     * storage paths directly.
     *
     * **Branch references.**
     * A path such as `/refs/branch/main` is a namespace entry backed by a
     * reference object. Its ParseProcedure rewrites the path to the physical
     * snapshot path (e.g. `/snapshots/abc123`). The caller's handle lands on the
     * snapshot. To advance the HEAD, the caller must explicitly open the reference
     * object itself with WRITE access, which is the sole contention point for that
     * branch.
     *
     * **Ephemeral relation resolution.**
     * An ephemeral relation produces tuples through a generator function rather
     * than physical storage; the generator may query base relations on behalf
     * of the runtime to materialise its output. The caller's handle and access
     * mask remain bound to the ephemeral relation. Base relations are accessed
     * only via the ephemeral relation's own type callbacks; the caller never
     * receives a handle on them and does not need explicit permission on them.
     * Capability security is enforced at the ephemeral-relation boundary, not
     * the base relation boundary.
     *
     * **Atomic multi-reference updates.**
     * Updating multiple references simultaneously (e.g. advancing both `main` and
     * `audit_log`) must be all-or-nothing. The implementation should acquire
     * exclusive locks on all target namespace entries before modifying any. If
     * LifecycleManager::Contention fails on any entry, all locks are released and
     * the batch is aborted. This preserves audit consistency.
     *
     * **Cycle guard.**
     * Ephemeral relation definitions may reference other ephemeral relations,
     * and branch aliases may chain. Name resolution must track reparse depth
     * and return an error after a bounded number of iterations to prevent
     * infinite cycles.
     *
     * **Audit branch.**
     * Audit requires global access dissociated from any data branch. It should be
     * modelled as an independent branch; its HEAD is the only contention point for
     * audit-affecting operations.
     *
     * @todo Implement `Resolve(path)` with a reparse loop and cycle depth guard.
     * @todo Define the reference object type with `object_type::exclusive = true`
     *       and a ParseProcedure that rewrites the resolution path.
     * @todo Define the batch-update API with all-or-nothing contention semantics.
     *       See docs/reactos-ob-comparison.md §8.
     */
    class NamespaceReferenceManager {
      public:
        /**
         * @brief Constructs a NamespaceReferenceManager bound to a registry.
         * @param objects Registry used to look up reference objects (branches,
         *                sessions) during reparse.
         * @param storage KV backend; required to read the branch-tree merkle
         *                nodes when resolving `/system/branches/<n>/<mg>/...`
         *                paths through to their snapshot.
         */
        NamespaceReferenceManager(ObjectManager& objects, IStorageBackend& storage);

        /**
         * @brief Rewrites a logical path through reference reparse rules.
         *
         * Currently handles branch references:
         *   /system/branches/<name>/<sub>... → /system/snapshots/<target_hash>/<sub>...
         * where target_hash is the value stored on the named Branch object. When
         * the branch is unborn (target_hash empty) or the rest of the path is
         * empty (caller is opening the branch object itself, not something
         * under it), the path is returned unchanged.
         *
         * Session paths (/system/sessions/<X>/branches/<name>/...) will be
         * added when SESSION objects exist; for now they are returned as-is.
         *
         * A 30-iteration cycle guard mirrors the ReactOS reparse cap. If the
         * guard trips the returned path is empty, signaling failure to the
         * caller (Find will subsequently miss).
         *
         * @param path Input logical path components.
         * @return Resolved path components, or empty vector on cycle/failure.
         */
        std::vector<std::string> Resolve(std::vector<std::string> path) const;

      private:
        ObjectManager& objects_;
        IStorageBackend& storage_;
    };
} // namespace nt
