#pragma once

#include "LifecycleManager.h"
#include "ObjectManager.h"

#include <string>
#include <utility>
#include <vector>

/**
 * @file EphemeralRelation.h
 * @brief Writer path and lifetime helpers for ephemeral relations.
 *
 * An ephemeral relation has no tuple storage of its own; its tuples are
 * produced on demand by a generator (see ObjectManager.h). Relational-algebra
 * operations (select, project, join) all yield one. The functions here register
 * such a relation into the object manager, hash its identity, pin the base
 * relations it is defined atop, and release session-owned entries at session
 * close.
 *
 * They are free functions over an ObjectManager and a LifecycleManager, not a
 * stateful manager object.
 *
 * See docs/ephemeral-relations.org for the lifetime model.
 */

namespace nt::Ephemeral {
    /**
     * @brief Lifetime class of a freshly produced ephemeral relation.
     *
     * Naming is what makes a result outlive its cursor: an anonymous result is
     * owned by nobody.
     *
     * - Scratch: an anonymous per-statement intermediate. Registered under
     *   /system/sessions/<session>/scratch/<root> and not session-pinned, so it
     *   is collected by reference counting once its consuming cursor closes.
     * - Named: a view-like binding. Registered under
     *   /system/sessions/<session>/ephemeral/<name> with one session-ownership
     *   Pin, so it survives between commands and can be re-requested. Released
     *   at rnt_session_close or (later) by the idle reaper.
     */
    enum class Tier { Scratch, Named };

    /**
     * @brief Splits a slash-joined logical path into registry components.
     *
     * Drops a leading slash and any empty segments, matching split_path in the
     * C API layer. Used by the writer path here and by
     * LifecycleManager::CascadeEphemeral when re-splitting stored dependency
     * paths at GC time.
     */
    std::vector<std::string> SplitPath(const std::string& path);

    /**
     * @brief Deterministic merkle_root for an ephemeral relation.
     *
     * Hashes SHA256 over the generator identity, the schema, and the
     * merkle_roots of the declared base relations. Two ephemerals with the same
     * operator, schema, and base roots hash identically, so a repeated query
     * reuses one registry entry instead of creating duplicates; rebinding a base
     * produces a new root that propagates like a tuple insertion in a stored
     * relation.
     *
     * Schema entries and base roots are sorted internally, so input order does
     * not affect the result.
     *
     * @param generator_identity Stable label of the producing operator/builtin
     *                            (e.g. "join", "select:age", "eq").
     * @param schema             (attribute_name, attribute_type) pairs.
     * @param base_roots         merkle_roots of the base relations, any order.
     * @return 64-char lowercase-hex SHA256 digest.
     */
    std::string ComposeRoot(const std::string& generator_identity,
                            const std::vector<std::pair<std::string, std::string>>& schema,
                            const std::vector<std::string>& base_roots);

    /**
     * @brief Registers an ephemeral relation produced by a relational operation.
     *
     * Resolves each dependency in the registry to read its current merkle_root
     * (for the identity hash) and to take a structural Pin on it: a base
     * relation cannot be GC'd while an ephemeral is defined atop it. Then
     * registers an EphemeralRelation IObject with an ephemeral_object_type
     * carrying the generator and cardinality. For Tier::Named, an extra
     * session-ownership Pin is taken so the entry outlives its cursor.
     *
     * Idempotent: an existing entry at the target path (identical scratch root,
     * or a live named binding) is returned without re-registering or
     * double-pinning.
     *
     * The caller should Monitor the returned entry when it opens a cursor over
     * it; a Scratch entry with no cursor and no session pin lingers until
     * session close.
     *
     * @param objects      Registry to register into.
     * @param lifecycles   Lifecycle manager for the dependency / ownership pins.
     * @param session_hash Owning session's hash (the namespace parent).
     * @param tier         Scratch (anonymous) or Named (session-owned).
     * @param name         Leaf name for Tier::Named; ignored for Tier::Scratch
     *                     (the composed root is used as the leaf instead).
     * @param generator    Tuple-producing generator for this relation.
     * @param cardinality  Finite / ConstrainedFinite / AlephZero / Continuum.
     * @param generator_identity Stable operator label, see ComposeRoot.
     * @param schema       (attribute_name, attribute_type) pairs.
     * @param dependencies Slash-joined logical paths (no leading slash) of the
     *                     base relations this is defined atop, e.g.
     *                     "system/snapshots/<h>/relations/<rel>". Stored verbatim
     *                     on the object and re-split at GC time. Every path must
     *                     resolve; an unresolvable dependency fails the whole
     *                     registration, since a stored-but-unpinned path would
     *                     make CascadeEphemeral Unpin a hold it never took.
     * @return Borrowed pointer to the registered (or pre-existing) entry, or
     *         nullptr on error (empty session hash, empty name for Tier::Named,
     *         or any unresolvable dependency).
     */
    ObjectManager::registry* Register(
        ObjectManager& objects, LifecycleManager& lifecycles, const std::string& session_hash,
        Tier tier, const std::string& name,
        ObjectManager::ephemeral_object_type::Generator generator,
        ObjectManager::ephemeral_object_type::Cardinality cardinality,
        const std::string& generator_identity,
        const std::vector<std::pair<std::string, std::string>>& schema,
        const std::vector<std::string>& dependencies);

    /**
     * @brief Releases all ephemeral relations owned by a session.
     *
     * Called by rnt_session_close before the session entry is removed. Named
     * entries directly under the session's "ephemeral" subdir have their
     * session-ownership Pin released (collecting them when no cursor or
     * dependent still holds them, cascading their base-relation Unpins). Scratch
     * entries under the session's "scratch" subdir were never session-pinned;
     * any that linger with no open cursor are collected directly. Entries still
     * held by an open cursor are left for the normal handle-release path.
     *
     * @param objects      Registry to walk.
     * @param lifecycles   Lifecycle manager driving the releases.
     * @param session_hash Session whose ephemerals to release.
     * @return Number of entries released or collected.
     */
    std::size_t ReleaseSession(ObjectManager& objects, LifecycleManager& lifecycles,
                               const std::string& session_hash);
} // namespace nt::Ephemeral
