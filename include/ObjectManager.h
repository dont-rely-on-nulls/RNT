#pragma once

#include "Api.h"
#include "Types.h"

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

/**
 * @file ObjectManager.h
 * @brief Declares the registry responsible for runtime-managed database objects.
 */

namespace nt {
    /**
     * @brief Owns the registry used to locate and reference database objects.
     *
     * The object manager is the central directory for runtime objects. It keeps
     * the metadata needed to reason about object type, path, references, and
     * handles while the concrete storage model is still being designed.
     */
    class ObjectManager {
      public:
        /** @brief Base type for objects stored in the registry. */
        class IObject {
          public:
            virtual ~IObject() = default;
        };

        /**
         * @brief Registry object representing a multigroup snapshot.
         *
         * `merkle_root` is the hex hash of the Merkle<std::string> root node
         * that maps relation_name → relation_merkle_root for this snapshot.
         * Updates are path-localised: inserting one tuple advances the root
         * through O(log_B) node rewrites, leaving sibling subtrees byte-
         * identical.
         *
         * Every commit produces a new Multigroup entry under
         * /system/snapshots/<merkle_root> with one child Relation per leaf at
         * /system/snapshots/<merkle_root>/relations/<relation_name>. Snapshots are
         * immutable (disposable=false, exclusive=false); the rest of the
         * system refers to them by hash. A Multigroup is eligible for GC
         * only when its reference_count drops to zero (no BRANCH_TREE still
         * pins it, no pinned cursor still references it).
         */
        class Multigroup : public IObject {
          public:
            std::string merkle_root;
        };
        /**
         * @brief Registry object representing a stored relation.
         *
         * merkle_root is the hex hash of the Merkle B-tree root node stored in
         * the KV backend.  Empty string means the relation contains no tuples.
         * Updated atomically by rnt_link_tuple / rnt_unlink_tuple / rnt_clear_relation.
         */
        class Relation : public IObject {
          public:
            std::string merkle_root;
        };
        /**
         * @brief Registry object representing an ephemeral relation.
         *
         * Ephemeral relations have no tuple storage of their own; tuples are
         * produced on demand by the generator function declared in the
         * ephemeral_object_type descriptor. They compose into a multigroup's
         * tree on equal footing with stored relations — only `merkle_root`
         * participates in the Merkle<std::string> entry for this relation,
         * regardless of how that root was derived.
         *
         * `merkle_root` is the SHA256 hex digest derived from the generator's
         * identity, the current schema, and the merkle_roots of the declared
         * base relations. Any mutation to structure or rebinding of a base
         * produces a new merkle_root, which then propagates into a new
         * multigroup snapshot exactly like a tuple insertion in a stored
         * relation.
         *
         * `dependencies` lists the logical paths of base relations this
         * ephemeral relation is defined atop of. The lifecycle manager Pins
         * each entry while this object is alive, preventing GC of a stored
         * relation that still backs an ephemeral one. The dependency list is
         * also the foundation for attribute-level provenance tracking added
         * later.
         *
         * The merkle_root composition function is nt::Ephemeral::ComposeRoot
         * (SHA256 over generator identity + schema + sorted base merkle_roots);
         * nt::Ephemeral::Register is the writer path that populates both
         * fields. See include/EphemeralRelation.h.
         */
        class EphemeralRelation : public IObject {
          public:
            std::string merkle_root;
            std::vector<std::string> dependencies;
        };
        /** @brief Abstract registry object representing a transaction. */
        class Transaction : public IObject {
          public:
            bool committed = false;
            std::vector<std::string> staged_branches;
            // Commit here means CAS each target_hash against observed,
            // swap, storage.Commit(), committed = true
            std::map<std::string, std::string>
                observed_roots; // branch root snapshot at first touch
            // Deferred new branch-tree root per staged branch. Writes inside a
            // txn buffer here instead of mutating the live Branch; commit swaps
            // these in once the CAS gate passes.
            std::map<std::string, std::string> pending_roots;
            // Snapshot multigroups freshly registered while staging. The commit
            // pins only those referenced by the committed branch-tree; the
            // intermediate (superseded) ones are never pinned. CascadeTransaction
            // sweeps this list when the txn is collected, so the ref-count guard
            // drops the unpinned intermediates (and, on abort, all of them) while
            // committed snapshots survive.
            std::vector<std::string> staged_snapshots;
        };

        /**
         * @brief Registry object representing an active connection's session.
         *
         * `connection_context` carries whatever auth/connection metadata the
         * caller passed to rnt_session_open. The runtime treats it as an
         * opaque pointer; ownership of the pointee is the caller's concern.
         *
         * `branch_overrides` maps a branch name to the BRANCH_TREE root this
         * session should see for that branch, instead of the global HEAD.
         * NamespaceReferenceManager::Resolve consults the override first when
         * a path of the form /system/sessions/<X>/branches/<name>/<sub>...
         * is requested, falling back to the global /system/branches/<name>
         * lookup when no override is present.
         *
         * The session→branch reference direction is intentional: global
         * branches do not track viewing sessions, which keeps the hot path
         * cheap. GC of a stale snapshot must walk all sessions' override
         * maps to discover live references — amortised cost only paid at GC
         * time. A reverse index can be added later if session counts make
         * the walk hot.
         */
        class Session : public IObject {
          public:
            void* connection_context = nullptr;
            std::map<std::string, std::string> branch_overrides;
        };

        /**
         * @brief A named mutable reference to a branch-tree root.
         *
         * `target_hash` is the merkle_root of a BRANCH_TREE — a
         * `Merkle<std::string>` root mapping `mg_name -> mg_hash`. Path
         * resolution walks the branch tree to translate
         * `/system/branches/<n>/multigroups/<mg>/relations/<rel>` into the
         * right `/system/snapshots/<mg_hash>/relations/<rel>`. Empty string
         * means the branch has no commits yet (unborn).
         *
         * Branches are the sole mutable pointer in the system; concurrent
         * writers serialize through LifecycleManager::Contention because the
         * BRANCH object_type carries exclusive=true. Readers never contend —
         * they resolve the branch through its tree to the immutable
         * Multigroups and operate on those.
         */
        class Branch : public IObject {
          public:
            std::string name;
            std::string target_hash;
        };

        /**
         * @brief Registry object for a branch-tree blob.
         *
         * `merkle_root` is the Merkle<std::string> root hash of the (mg_name,
         * mg_hash) tree this entry indexes. The same blob is referenced by
         * every BRANCH and session override sharing this tip. Lifecycles:
         *
         *   - Pinned once per referencing BRANCH or session override.
         *   - When its reference count drops to zero,
         *     LifecycleManager::CascadeBranchTree pages the tree and unpins
         *     each multigroup it references before unregistering the entry.
         */
        class BranchTree : public IObject {
          public:
            std::string merkle_root;
        };

        /**
         * @brief Describes the behavior and capabilities of an object category.
         *
         * @todo Replace `methods` with typed callback fields: `OpenProcedure`,
         *       `CloseProcedure`, `DeleteProcedure`, and `ParseProcedure`.
         *       Store a `const char* name` label alongside each callback so that
         *       logs and assertions can identify which type fired without having
         *       to dereference a pointer. `IdentityManager::CanOpen` / `CanClose`
         *       then become thin dispatchers that invoke the corresponding
         *       procedure, or are absorbed into `HandlerManager` directly.
         *       See docs/reactos-ob-comparison.md §2.
         *
         * @todo Add an `exclusive` flag for mutable reference objects (branch
         *       HEADs, namespace entries). Non-exclusive objects — immutable
         *       snapshots, transactions — must skip contention checks entirely.
         *       See docs/reactos-ob-comparison.md §6.
         */
        struct object_type {
            /** Object category label. */
            OBJECT_TYPE label;
            /** True when the object is not durable. For example: TRANSACTION. */
            bool disposable;
            /**
             * Methods supported by this object type.
             * @todo Replace with typed callback function pointers. See class-level todo.
             */
            std::set<METHOD> methods;
            /**
             * When true, only one write-mode handle may be open at a time.
             * Applies to mutable reference states such as branch HEADs.
             * Immutable snapshot objects must leave this false.
             * @todo Wire into LifecycleManager::Contention.
             */
            bool exclusive = false;

            virtual ~object_type() = default;
        };

        /**
         * @brief Object type descriptor for EPHEMERAL_RELATION objects.
         *
         * An ephemeral relation has no physical storage. Its tuples are produced
         * on demand by a generator function. Cardinality may be finite (e.g. a
         * projected stored relation) or AlephZero (e.g. the eq/lt builtins).
         *
         * The generator receives the bound argument values that were written into
         * the cursor by the JOIN operator before each probe, together with a
         * pagination offset and limit. It must return at most `limit` tuples
         * starting at logical position `offset`.
         *
         * For membership-probe builtins (all args ground), the generator returns
         * at most one tuple. For enumeration over AlephZero relations the generator
         * maps `offset` to the appropriate pair via a bijective enumeration scheme
         * (e.g. Cantor pairing); callers must bound such scans with a TAKE node.
         */
        struct ephemeral_object_type : object_type {
            enum class Cardinality { Finite, ConstrainedFinite, AlephZero, Continuum };

            /**
             * @brief Produces a page of tuples for the given bound arguments.
             * @param args   Bound argument values written by the JOIN before probing.
             * @param offset Zero-based logical tuple offset (for pagination).
             * @param limit  Maximum number of tuples to return.
             */
            using Generator = std::function<std::vector<Tuple>(
                const std::vector<std::string>& args, std::size_t offset, std::size_t limit)>;

            Cardinality cardinality;
            Generator generator;
        };

        /**
         * @brief Shared metadata stored at the head of a registry entry.
         *
         * Two independent reference counters govern object lifetime.
         * An object is eligible for garbage collection only when both reach zero:
         *
         * - `handle_count` — open sessions holding a cursor or handle on this object.
         *   Managed exclusively by LifecycleManager::Monitor / Unmonitor.
         * - `reference_count` — structural dependencies such as an ephemeral relation
         *   referencing its base relations, or a cursor pinned to an immutable snapshot
         *   version.
         *   Managed by LifecycleManager::Pin / Unpin (not yet implemented).
         *
         * All snapshot versions are immutable. An insertion or deletion produces a new
         * snapshot rather than mutating an existing one. A snapshot's `reference_count`
         * is non-zero while any cursor is pinned to it and drops to zero only when all
         * such cursors are released.
         *
         * @todo Implement `reference_count` tracking. Add LifecycleManager::Pin /
         *       Unpin. Update LifecycleManager::Unmonitor to gate GC on both counters
         *       reaching zero. See docs/reactos-ob-comparison.md §1.
         *
         * @todo Define and attach a security_descriptor. When added, store it as a
         *       pointer into a shared, content-addressed SD cache rather than inline.
         *       Permissions are strictly capability-based and must never be inherited
         *       from a parent namespace entry. See docs/reactos-ob-comparison.md §5.
         */
        struct registry_head {
            /**
             * Structural dependency count. Non-zero while another registry object
             * references this one (e.g. an ephemeral relation depending on a base
             * relation, or a cursor pinned to a snapshot version).
             * @todo Implement via LifecycleManager::Pin / Unpin.
             */
            uint32_t reference_count = 0;
            /** Number of open handles. Maintained by LifecycleManager::Monitor/Unmonitor. */
            uint32_t handle_count = 0;
            /** Object type metadata. Owned by this head. */
            std::unique_ptr<object_type> type;
            /** Logical object path inside the namespace. */
            std::vector<std::string> path;
        };

        /** @brief Node in the object registry. */
        struct registry {
            /** Shared metadata for this object. */
            std::unique_ptr<registry_head> head;
            /** Abstract object payload. Owned by this entry. */
            std::unique_ptr<IObject> object;
            /**
             * Next entry in the registry. Currently a flat linked list.
             * @todo Replace with a trie whose nodes are per-path-segment hash maps.
             *       Each directory level holds a hash map from segment string to
             *       child registry*. Find() and Register() walk the trie
             *       component-by-component instead of scanning a flat list.
             *       Consider pulling a well-tested radix-tree via the Nix flake rather than
             *       implementing from scratch. See docs/reactos-ob-comparison.md §3.
             */
            std::unique_ptr<registry> next;
        };

        /** @brief Head of the registry linked list. Owned by this manager. */
        std::unique_ptr<registry> entries;

        /**
         * @brief Registers an object under the given path, taking ownership of it.
         * @param path    Logical object path.
         * @param object  Object payload. Ownership is transferred to the registry.
         * @param type    Object type descriptor. Ownership is transferred to the registry.
         */
        void Register(std::vector<std::string> path, std::unique_ptr<IObject> object,
                      std::unique_ptr<object_type> type);

        /**
         * @brief Looks into this registry and attempts to retrieve an entry.
         * @param object_path Logical path to search for.
         * @return Borrowed pointer to the matching entry, or nullptr when not found.
         */
        registry* Find(const std::vector<std::string> object_path);

        /**
         * @brief Removes the entry registered at @p object_path, if any.
         *
         * Splices the matching node out of the registry list and frees its
         * owned object and head. No reference-count checks are performed —
         * the caller is responsible for releasing handles and pins before
         * calling this. Intended for disposable objects (sessions today,
         * other disposables once GC lands in step 6).
         *
         * @param object_path Logical path of the entry to remove.
         * @return True when an entry was removed, false when nothing matched.
         */
        bool Unregister(const std::vector<std::string>& object_path);
    };
} // namespace nt
