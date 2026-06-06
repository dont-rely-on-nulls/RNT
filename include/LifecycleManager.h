#pragma once

#include "Api.h"
#include "IStorageBackend.h"
#include "ObjectManager.h"

/**
 * @file LifecycleManager.h
 * @brief Declares monitoring, pinning, cleanup, and contention operations.
 */

namespace nt {
    /**
     * @brief Manages runtime lifecycle concerns for registry objects.
     *
     * Object lifetime is governed by two independent counters in registry_head:
     * `handle_count` (sessions holding an open handle) and `reference_count`
     * (structural dependencies such as cursors pinned to a snapshot or
     * ephemeral relations referencing their base relations). An object is
     * eligible for GC only when both reach zero.
     *
     * Monitor / Unmonitor manage `handle_count`. Pin / Unpin manage
     * `reference_count`. See docs/reactos-ob-comparison.md §1.
     */
    class LifecycleManager {
      public:
        /**
         * @brief Constructs a LifecycleManager bound to a registry and store.
         *
         * Needs the registry to perform GC: Unmonitor and Unpin call
         * ObjectManager::Unregister once both counters reach zero. Type-specific
         * cleanup (e.g. cascading a Multigroup's pin to its child Relations,
         * or a BranchTree's pin to its child Multigroups) runs inside the
         * lifecycle manager before the entry is spliced out. The storage
         * backend is needed by CascadeBranchTree to page the merkle nodes.
         */
        LifecycleManager(ObjectManager& objects, IStorageBackend& storage);

        /**
         * @brief Starts monitoring an object's lifecycle.
         *
         * Increments `handle_count` on the object's registry_head. Should be
         * called after all authorization checks pass inside HandlerManager::Open.
         *
         * @param object Object to monitor.
         */
        void Monitor(ObjectManager::registry* object);

        /**
         * @brief Stops monitoring an object.
         *
         * Decrements `handle_count`. When both `handle_count` and
         * `reference_count` reach zero, the object becomes eligible for GC.
         *
         * @todo Gate GC on both counters reaching zero, not just handle_count.
         *       For deferred compaction, enqueue onto a background GC list rather
         *       than freeing inline. See docs/reactos-ob-comparison.md §1 and §7.
         *
         * @param object Object to stop monitoring.
         */
        void Unmonitor(ObjectManager::registry* object);

        /**
         * @brief Increments the structural dependency count on an object.
         *
         * Call when one object takes a dependency on another — for example when
         * a cursor pins an immutable snapshot version, or when an ephemeral
         * relation is registered against its base relations. Prevents GC of the
         * target object while the dependency is live.
         *
         * @todo Implement. See docs/reactos-ob-comparison.md §1.
         *
         * @param object Object being depended upon.
         */
        void Pin(ObjectManager::registry* object);

        /**
         * @brief Decrements the structural dependency count on an object.
         *
         * The inverse of Pin. When both `reference_count` and `handle_count`
         * reach zero the object becomes eligible for GC.
         *
         * @todo Implement. See docs/reactos-ob-comparison.md §1.
         *
         * @param object Object whose dependency is being released.
         */
        void Unpin(ObjectManager::registry* object);

        /**
         * @brief Returns true when the object is GC-eligible right now.
         *
         * Eligibility is the joint condition handle_count == 0 &&
         * reference_count == 0. Decrement callers (Unmonitor / Unpin) consult
         * this and, when true, run type-specific cleanup before unregistering.
         */
        bool IsEligibleForGC(ObjectManager::registry* object) const;

        /**
         * @brief Serializes contention for changes to mutable reference states.
         *
         * Immutable objects — relation snapshots, multigroup snapshots,
         * transactions — never raise contention. Two sessions opening the same
         * immutable snapshot simultaneously is always safe; they will produce
         * independent results without conflict.
         *
         * Contention applies only to mutable reference states: the HEAD of a
         * branch and namespace entries targeted by atomic multi-reference updates.
         * These are the sole mutable pointers in the system. When a session holds
         * a write handle on a HEAD, a second write opener must block or fail.
         *
         * @todo Implement: read `object_type::exclusive`. Return false immediately
         *       for non-exclusive objects. For exclusive objects, return false
         *       (contention detected) when `handle_count > 0` for a write-mode
         *       opener. See docs/reactos-ob-comparison.md §6.
         *
         * @param object Object to check for contention.
         * @return True when the operation may proceed.
         */
        const bool Contention(ObjectManager::registry* object);

      private:
        /**
         * @brief Joint-counters check + type-specific cascade + Unregister.
         *
         * Called by Unmonitor and Unpin after their decrement. No-op when the
         * object is still referenced. When eligible:
         *   - MULTIGROUP entries first unpin every Relation registered as a
         *     direct child of their /system/snapshots/H subtree.
         *   - BRANCH_TREE entries first unpin every Multigroup their
         *     content-addressed tree references.
         *   - The entry is then removed from the registry; its IObject and
         *     registry_head are freed.
         *
         * Inline GC for now; the reaper-queue deferred-deletion pattern from
         * docs/reactos-ob-comparison.md §7 is a later optimisation.
         */
        void TryCollect(ObjectManager::registry* object);

        /**
         * @brief Releases pins held by a MULTIGROUP entry on its child Relations.
         *
         * Iterates the registry once, collects every /system/snapshots/<H>/<n>
         * direct child, and calls Unpin on each. Triggered exclusively from
         * TryCollect at the moment the parent snapshot becomes eligible for GC.
         */
        void CascadeMultigroup(ObjectManager::registry* multigroup);

        /**
         * @brief Releases pins held by a BRANCH_TREE entry on its child mgs.
         *
         * Pages the Merkle<std::string> tree at the BranchTree's merkle_root,
         * resolves each (mg_name, mg_hash) entry to its
         * /system/snapshots/<mg_hash> Multigroup, and calls Unpin on it.
         * Triggered exclusively from TryCollect at the moment the BranchTree
         * itself becomes eligible for GC.
         */
        void CascadeBranchTree(ObjectManager::registry* branch_tree);

        ObjectManager& objects_;
        IStorageBackend& storage_;
    };
} // namespace nt
