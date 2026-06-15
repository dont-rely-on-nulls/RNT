#pragma once

/**
 * @file RNT_C_API.h
 * @brief C-callable surface over the RNT manager pipeline for OCaml ctypes.
 *
 * All types are opaque void pointers on the C side; the implementation casts
 * them to the appropriate C++ types internally. Callers must never dereference
 * handle or cursor pointers directly.
 *
 * ## Memory contract
 *   - Strings returned via out-parameters (char**) are heap-allocated by the
 *     API and must be released with rnt_free_string().
 *   - Payloads returned via (uint8_t**, size_t*) are heap-allocated and must
 *     be released with rnt_free_bytes().
 *   - Handles and cursors are owned by the caller and must be closed before
 *     the program exits.
 *
 * ## Error convention
 *   - Functions returning int use 0 for success and a negative value for error.
 *   - Functions returning a pointer return NULL on failure.
 *
 * ## Thread safety
 *   This API is **not thread-safe**. The global runtime (g_rt) is a single
 *   in-process instance; all callers share the same ObjectManager and storage
 *   backend. The expected usage model is a single OCaml thread (or domain)
 *   driving the API at a time. If concurrent access is needed in the future,
 *   a per-object or per-relation mutex strategy should be introduced.
 *
 * @todo Implement AUTH_CLAIM::READ/WRITE enforcement in rnt_open_handle once
 *       PermissionsManager::Access is wired to a real policy engine. Currently
 *       all handles open with full access regardless of the claims parameter.
 */

#include <stddef.h>
#include <stdint.h>

#include "Api.h"
#include "VM.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Opaque handle to a registry object opened through HandlerManager. */
typedef void* rnt_handle_t;

/** Opaque cursor over a relation, driven by the VM or used directly. */
typedef void* rnt_cursor_t;

/* ------------------------------------------------------------------ */
/* Runtime lifecycle                                                  */
/* ------------------------------------------------------------------ */

/**
 * @brief Initializes the RNT runtime with the selected storage backend.
 *
 * Must be called before any other API function. Once the runtime is
 * successfully initialized, subsequent calls are no-ops and return 0.
 * If initialization fails (returns negative), the call may be retried
 * with corrected parameters — the runtime is left in a clean state.
 *
 * @param driver        Storage driver to use: "sqlite" or "memory".
 *                      "sqlite" persists data to @p storage_path.
 *                      "memory" keeps all data in process memory (ignores
 *                      @p storage_path); intended for tests.
 * @param storage_path  File path for the SQLite database, or ":memory:" for
 *                      an ephemeral SQLite store. Ignored when driver is
 *                      "memory".
 * @return 0 on success, negative on error.
 */
NT_API int rnt_init(const char* driver, const char* storage_path);

/* ------------------------------------------------------------------ */
/* Authentication                                                       */
/* ------------------------------------------------------------------ */

/**
 * @brief Runs PermissionsManager::Firewall for a connection.
 *
 * @param auth_method  "plain_text" or "certificate".
 * @param claims_out   Set to a heap-allocated, newline-separated claim string.
 *                     Release with rnt_free_string(). NULL on error.
 * @return 0 on success, negative when authentication is rejected.
 */
NT_API int rnt_firewall(const char* auth_method, char** claims_out);

/* ------------------------------------------------------------------ */
/* Session lifecycle                                                    */
/* ------------------------------------------------------------------ */

/**
 * @brief Opens a session and registers it at /system/sessions/<hash>.
 *
 * The runtime mints a random 256-bit hex hash for the session; the caller
 * has no influence over the value. The returned string is the opaque
 * identifier required by every other rnt_session_* call.
 *
 * @param connection_context  Caller-owned pointer carried on the session.
 *                            The runtime treats it as opaque; ownership of
 *                            the pointee remains with the caller.
 * @param session_hash_out    Set to a heap-allocated 64-char hex string.
 *                            Release with rnt_free_string().
 * @return 0 on success, negative on error.
 */
NT_API int rnt_session_open(void* connection_context, char** session_hash_out);

/**
 * @brief Closes a session, unregistering it from /system/sessions/<hash>.
 *
 * After this call the session hash is invalid; subsequent rnt_session_* or
 * resolver lookups against it will fail. Branch overrides held by the
 * session are dropped.
 *
 * @param session_hash  Hash returned by rnt_session_open.
 * @return 0 on success, negative when the hash does not match an active session.
 */
NT_API int rnt_session_close(const char* session_hash);

/**
 * @brief Sets a per-session override for a branch.
 *
 * While the override is in effect, paths resolved through
 * /system/sessions/<hash>/branches/<branch_name>/... point at
 * /system/snapshots/<target_hash>/... regardless of where the global branch
 * HEAD currently sits. Pass an empty string for @p target_hash to remove
 * the override and resume falling back to the global branch.
 *
 * Non-empty target hashes must correspond to an existing
 * /system/snapshots/<target_hash> entry; otherwise the call fails.
 *
 * @param session_hash  Session identifier.
 * @param branch_name   Branch the override applies to (e.g. "main").
 * @param target_hash   Snapshot hash to bind, or "" to clear.
 * @return 0 on success, negative on error.
 */
NT_API int rnt_session_set_branch(const char* session_hash, const char* branch_name,
                                  const char* target_hash);

/* ------------------------------------------------------------------ */
/* Ephemeral relations                                                  */
/* ------------------------------------------------------------------ */

/**
 * Opaque sink passed to a generator callback. The callback pushes each tuple
 * it produces through rnt_sink_emit; the runtime copies the tuple out
 * immediately, so the string only needs to stay valid for the duration of
 * the rnt_sink_emit call.
 */
typedef void* rnt_tuple_sink_t;

/**
 * @brief Tuple-producing callback backing an ephemeral relation.
 *
 * Invoked by the cursor layer each time a page of tuples is needed. The
 * callback must emit at most @p limit tuples starting at logical position
 * @p offset by calling rnt_sink_emit once per tuple. Calls may re-enter the
 * RNT API (e.g. to execute a VM plan over base relations); the runtime is
 * single-threaded, so no locking is required.
 *
 * @param ctx     Opaque context pointer given at registration time.
 * @param args    Bound argument values written by a JOIN before probing,
 *                newline-separated. Empty string when scanned standalone.
 * @param offset  Zero-based logical tuple offset (for pagination).
 * @param limit   Maximum number of tuples to emit.
 * @param sink    Pass to rnt_sink_emit for each produced tuple.
 * @return 0 on success, negative on error (the page is treated as empty).
 */
typedef int (*rnt_generator_fn)(void* ctx, const char* args, size_t offset, size_t limit,
                                rnt_tuple_sink_t sink);

/**
 * @brief Emits one tuple from inside a generator callback.
 *
 * @param sink      Sink received by the callback.
 * @param tuple_kv  Newline-separated "name=value" attribute lines — the same
 *                  wire format rnt_link_tuple consumes and rnt_cursor_next
 *                  returns. Copied before returning.
 * @return 0 on success, negative on error.
 */
NT_API int rnt_sink_emit(rnt_tuple_sink_t sink, const char* tuple_kv);

/**
 * @brief Registers an ephemeral relation owned by a session.
 *
 * An ephemeral relation has no tuple storage of its own: its tuples are
 * produced on demand by @p generator. The entry lands under the session's
 * namespace — /system/sessions/<hash>/ephemeral/<name> when @p named is
 * non-zero (a named binding that survives between commands until dropped or
 * session close), or /system/sessions/<hash>/scratch/<composed_root> when
 * zero (an anonymous intermediate collected as soon as its consuming cursor
 * closes). Scan it through the normal pipeline: rnt_open_handle on the
 * registered path, then rnt_cursor_open / rnt_plan_scan.
 *
 * Registration pins every dependency, so a base relation cannot be collected
 * while this relation is defined atop it; the pins are released when the
 * ephemeral itself is collected. Registration is idempotent for an identical
 * scratch result or a live named binding. See docs/ephemeral-relations.org.
 *
 * @param session_hash        Hash returned by rnt_session_open.
 * @param named               Non-zero for a named binding, 0 for scratch.
 * @param name                Leaf name for named bindings; ignored for scratch.
 * @param generator           Tuple-producing callback. Must stay callable until
 *                            the entry is collected.
 * @param generator_ctx       Opaque pointer passed back to @p generator.
 * @param cardinality         0 Finite, 1 ConstrainedFinite, 2 AlephZero,
 *                            3 Continuum.
 * @param generator_identity  Stable operator label for the identity hash,
 *                            e.g. "join:id", "select:age".
 * @param schema_kv           Newline-separated "name=type" attribute lines.
 * @param dependencies        Newline-separated logical paths of the base
 *                            relations this is defined atop, e.g.
 *                            "system/snapshots/<h>/relations/<rel>". Every
 *                            path must resolve or the call fails.
 * @param path_out            Optional (may be NULL): set to the heap-allocated
 *                            slash-joined registered path. Release with
 *                            rnt_free_string().
 * @return 0 on success, negative on error.
 */
NT_API int rnt_register_ephemeral_relation(const char* session_hash, int named, const char* name,
                                           rnt_generator_fn generator, void* generator_ctx,
                                           int cardinality, const char* generator_identity,
                                           const char* schema_kv, const char* dependencies,
                                           char** path_out);

/**
 * @brief Drops a named ephemeral relation, releasing its session-ownership pin.
 *
 * The entry is collected as soon as no cursor or dependent ephemeral still
 * holds it, cascading the pins it took on its base relations. Scratch entries
 * cannot be dropped by name; they die with their consuming cursor.
 *
 * @param session_hash  Owning session's hash.
 * @param name          Leaf name given at registration.
 * @return 0 on success, negative when no such named binding exists.
 */
NT_API int rnt_drop_ephemeral_relation(const char* session_hash, const char* name);

/* ------------------------------------------------------------------ */
/* Handle lifecycle                                                     */
/* ------------------------------------------------------------------ */

/**
 * @brief Opens a handle to the object at the given slash-separated path.
 *
 * Runs the full HandlerManager::Open pipeline:
 * ObjectManager::Find → PermissionsManager::Access →
 * IdentityManager::CanOpen → LifecycleManager::Contention →
 * LifecycleManager::Monitor.
 *
 * @param path    Slash-separated logical path, e.g. "/system/branches/main".
 * @param claims  Claim string returned by rnt_firewall (may be NULL).
 * @return Handle pointer, or NULL when the path is not found or access is denied.
 */
NT_API rnt_handle_t rnt_open_handle(const char* path, const char* claims);

/**
 * @brief Closes a handle, running HandlerManager::Close and Unmonitor.
 * @return 0 on success, negative on error.
 */
NT_API int rnt_close_handle(rnt_handle_t handle);

/**
 * @brief Reads the current branch-tree root hash from a BRANCH object.
 *
 * Only valid for handles opened on BRANCH objects. The returned string is
 * the merkle_root of the BRANCH_TREE this branch currently points at — a
 * `Merkle<std::string>` root mapping mg_name → mg_hash. An empty string
 * indicates an unborn branch with no commits yet.
 *
 * @param handle           Handle to a BRANCH object.
 * @param target_hash_out  Set to a heap-allocated copy of the target hash
 *                         (possibly empty). Release with rnt_free_string().
 * @return 0 on success, negative when the handle is not a BRANCH.
 */
NT_API int rnt_branch_target(rnt_handle_t handle, char** target_hash_out);

/**
 * @brief Atomically advances a branch to point at a new branch-tree root.
 *
 * The new hash must already exist as a content-addressed blob in the KV
 * store — branch-tree roots are produced by mutating calls (rnt_link_tuple,
 * rnt_register_relation, …) and cannot be invented externally. Pass an
 * empty string to reset the branch to unborn.
 *
 * Write exclusion is structural: BRANCH objects carry @c exclusive=true in
 * their object_type, so LifecycleManager::Contention prevents a second handle
 * from being opened while a writer holds the branch. AUTH_CLAIM::WRITE is not
 * checked at the C API boundary.
 *
 * @param branch_path  Slash-separated branch path, e.g. "/system/branches/main".
 * @param new_hash     Branch-tree root to advance to (64-char lowercase hex),
 *                     or "" to reset to unborn.
 * @return 0 on success, negative when the branch is not found, the type is
 *         not BRANCH, or @p new_hash is non-empty but no matching blob
 *         exists in the KV store.
 */
NT_API int rnt_branch_advance(const char* branch_path, const char* new_hash);

/* ------------------------------------------------------------------ */
/* Object registration                                                  */
/* ------------------------------------------------------------------ */

/**
 * @brief Registers a RELATION object at the given path.
 *
 * Idempotent: if an object already exists at the path, the call succeeds
 * without re-registering.
 *
 * @param path Slash-separated path of the form
 *             "/system/branches/<branch>/multigroups/<mg>/relations/<rel>".
 * @return 0 on success, negative on error.
 */
NT_API int rnt_register_relation(const char* path);

/**
 * @brief Registers a BRANCH object at the given path pointing at a branch-tree root.
 *
 * If a BRANCH already exists at this path, returns 0 without modifying it.
 * When @p target_hash is non-NULL and non-empty it must already exist as a
 * content-addressed blob in the KV store (produced by an earlier mutation
 * through the same runtime); otherwise the call fails. Pass NULL or "" to
 * register an unborn branch.
 *
 * @param path         Slash-separated path, e.g. "/system/branches/main".
 * @param target_hash  Branch-tree root this branch points at (may be NULL
 *                     or "" for unborn).
 * @return 0 on success, negative on error.
 */
NT_API int rnt_register_branch(const char* path, const char* target_hash);

/**
 * @brief Lists all relations of a specific multigroup under a branch.
 *
 * Returns a newline-delimited string of "name\troot_hash" pairs, one per
 * relation in the named multigroup at the branch's current tree. An unborn
 * branch or an mg absent from the branch tree yields an empty string. The
 * caller must release the string with rnt_free_string().
 *
 * @param branch_mg_path  Slash-separated path of the form
 *                        "/system/branches/<name>/multigroups/<mg>".
 * @param out             Set to a heap-allocated "name\troot\n" string.
 *                        Release with rnt_free_string(). NULL on error.
 * @return 0 on success, negative when the path shape is wrong or the branch
 *         is not found.
 */
NT_API int rnt_list_relations(const char* branch_mg_path, char** out);

/**
 * @brief Lists all multigroups bound to a branch.
 *
 * Reads the branch-tree root from `/system/branches/<name>` and pages each
 * (mg_name, mg_hash) entry. Returns "name\thash\n" lines. Unborn branches
 * yield an empty string.
 *
 * @param branch_path  Slash-separated branch path, e.g. "/system/branches/main".
 * @param out          Heap-allocated string; release with rnt_free_string().
 * @return 0 on success, negative when the branch is not found.
 */
NT_API int rnt_list_branch_multigroups(const char* branch_path, char** out);

/**
 * @brief Lists all relations stored in a specific snapshot.
 *
 * Reads the multigroup codec directly from the snapshot at
 * /system/snapshots/<snapshot_hash> without following any branch HEAD.
 * Use this when the desired snapshot hash is already known (e.g. detached
 * checkout). Returns the same "name\troot_hash\n" format as rnt_list_relations.
 *
 * @param snapshot_hash  64-char hex hash of the snapshot.
 * @param out            Set to heap-allocated string. Release with rnt_free_string().
 * @return 0 on success, negative when the snapshot is not registered.
 */
NT_API int rnt_list_snapshot_relations(const char* snapshot_hash, char** out);

/* ------------------------------------------------------------------ */
/* Tuple storage                                                        */
/* ------------------------------------------------------------------ */

/**
 * @brief Stores a tuple and links it to the relation at the given path.
 *
 * Tuples are encoded as a flat key=value string, one attribute per line:
 *   "name=Blathers\nprofession=Museum Curator\n"
 * Attributes are sorted by name before hashing to ensure content-addressing
 * is order-independent.
 *
 * @param relation_path  Slash-separated relation path.
 * @param kv_attrs       Newline-delimited "key=value" attribute string.
 * @param hash_out       Set to the 64-character hex SHA-256 hash of the tuple.
 *                       Release with rnt_free_string(). NULL on error.
 * @return 0 on success, negative on error.
 */
NT_API int rnt_link_tuple(const char* relation_path, const char* kv_attrs, char** hash_out);

/**
 * @brief Removes a tuple from the relation's Merkle tree and tuple store.
 *
 * Calls Merkle::Remove on the relation's current root and updates
 * ObjectManager::Relation::merkle_root atomically.  The tuple bytes remain in
 * the KV store (they may be referenced by older snapshots); only the
 * membership in the current tree is removed.
 *
 * @param relation_path  Slash-separated relation path.
 * @param tuple_hash     64-character hex SHA-256 of the tuple to remove.
 * @return 0 on success, negative when the relation is not found.
 */
NT_API int rnt_unlink_tuple(const char* relation_path, const char* tuple_hash);

/**
 * @brief Resets a relation's Merkle root to the empty-tree state.
 *
 * Sets ObjectManager::Relation::merkle_root to the empty string.  Existing
 * tuple bytes remain in the KV store.  After this call the relation contains
 * no tuples from the perspective of cursor iteration.
 *
 * @param relation_path  Slash-separated relation path.
 * @return 0 on success, negative when the relation is not found.
 */
NT_API int rnt_clear_relation(const char* relation_path);

/**
 * @brief Returns the current Merkle root hash for a relation.
 *
 * OCaml calls this after rnt_link_tuple or rnt_unlink_tuple to read the
 * updated root back and store it in the in-memory multigroup (tree_pointer).
 * An empty string is returned for a relation that contains no tuples.
 *
 * @param relation_path  Slash-separated relation path.
 * @param root_hash_out  Set to the 64-character hex root hash, or to an empty
 *                       heap-allocated string for an empty relation.
 *                       Release with rnt_free_string().
 * @return 0 on success, negative when the relation is not found.
 */
NT_API int rnt_relation_root(const char* relation_path, char** root_hash_out);

/* ------------------------------------------------------------------ */
/* Cursor and VM                                                        */
/* ------------------------------------------------------------------ */

/**
 * @brief Opens a cursor on the relation referenced by handle.
 *
 * The returned cursor is positioned before the first tuple. Advance it with
 * rnt_cursor_next(). The cursor must be closed with rnt_cursor_close() before
 * closing the handle.
 *
 * @param handle  Open RELATION handle.
 * @return Cursor pointer, or NULL on error.
 */
NT_API rnt_cursor_t rnt_cursor_open(rnt_handle_t handle);

/**
 * @brief Advances the cursor and returns the next tuple as a kv string.
 *
 * The tuple is encoded as a newline-delimited "key=value" string matching the
 * format accepted by rnt_link_tuple:
 *   "name=Blathers\nprofession=Museum Curator\n"
 *
 * @param cursor       Open cursor.
 * @param tuple_out    Set to a heap-allocated kv string, or NULL when exhausted.
 *                     Release with rnt_free_string() when non-NULL.
 * @return 1 when a tuple was returned, 0 when exhausted, negative on error.
 */
NT_API int rnt_cursor_next(rnt_cursor_t cursor, char** tuple_out);

/**
 * @brief Closes a cursor and releases its resources.
 * @return 0 on success, negative on error.
 */
NT_API int rnt_cursor_close(rnt_cursor_t cursor);

/* ------------------------------------------------------------------ */
/* VM plan builder                                                      */
/* ------------------------------------------------------------------ */

/** Opaque plan node tree, built via rnt_plan_assemble calls. */
typedef void* rnt_plan_t;

/**
 * SCAN context: reads all tuples from a stored relation.
 *
 * @param relation_path  Absolute slash-separated path, e.g.
 *  "/system/branches/main/multigroups/warehouse/relations/public:users".
 */
typedef struct {
    const char* relation_path;
} PlanArgsScan;

/**
 * JOIN context: nested-loop join of two child plans.
 *
 * Takes ownership of both children. They are released when the assembled plan
 * is freed or executed; on failure both are freed.
 */
typedef struct {
    rnt_plan_t left;
    rnt_plan_t right;
} PlanArgsJoin;

/**
 * TAKE context: passes at most @p limit tuples from @p source, then stops.
 *
 * Takes ownership of @p source; on failure @p source is freed.
 */
typedef struct {
    rnt_plan_t source;
    size_t limit;
} PlanArgsTake;

/**
 * PROJECT context: keeps only the named attributes of @p source.
 *
 * @p attrs is a NULL-terminated array of attribute names to retain, e.g.
 * <tt>{ "name", "profession", NULL }</tt>. Takes ownership of @p source; on
 * failure @p source is freed.
 */
typedef struct {
    rnt_plan_t source;
    const char** attrs;
} PlanArgsProject;

/**
 * A single plan-construction request. @p operation selects which context member
 * is read; the others are ignored. The members are laid out side by side rather
 * than overlapped in a union so the struct maps cleanly onto OCaml ctypes, which
 * has no union support. Only the member matching @p operation need be populated.
 */
typedef struct {
    nt::Operation operation;
    PlanArgsScan scan;
    PlanArgsJoin join;
    PlanArgsTake take;
    PlanArgsProject project;
} PlanAction;

/**
 * @brief Builds one plan node from @p action and returns the resulting subtree.
 *
 * Sole entry point for plan construction. Validates runtime state once, then
 * dispatches on @p action.op. Child plans for JOIN/TAKE/PROJECT are themselves
 * results of prior rnt_plan_assemble calls; ownership transfers per the
 * per-operator rules documented on each PlanArgs* struct.
 *
 * @return Plan node, or NULL when the runtime is uninitialised or construction
 *         fails (e.g. relation does not exist).
 */
NT_API rnt_plan_t rnt_plan_assemble(PlanAction action);

/**
 * @brief Releases a plan that was built but not yet executed.
 *
 * Closes any open cursors and handles owned by the plan tree, then frees all
 * nodes. Safe to call with NULL. Do NOT call after rnt_vm_execute_plan —
 * that function takes ownership.
 */
NT_API void rnt_plan_free(rnt_plan_t plan);

/**
 * @brief Executes a plan tree and returns a streaming VM cursor.
 *
 * Takes ownership of @p plan; the caller must not call rnt_plan_free after this.
 * The returned cursor is advanced with rnt_vm_cursor_next() and must be closed
 * with rnt_vm_cursor_close(), which also releases all plan resources.
 *
 * @return VM cursor, or NULL when the plan is NULL.
 */
NT_API rnt_cursor_t rnt_vm_execute_plan(rnt_plan_t plan);

/**
 * @brief Advances a VM cursor and returns the next merged tuple as a kv string.
 *
 * Same encoding and return-value semantics as rnt_cursor_next.
 *
 * @param vm_cursor  Cursor returned by rnt_vm_execute_plan.
 * @param tuple_out  Set to a heap-allocated kv string, or NULL when exhausted.
 *                   Release with rnt_free_string() when non-NULL.
 * @return 1 when a tuple was returned, 0 when exhausted, negative on error.
 */
NT_API int rnt_vm_cursor_next(rnt_cursor_t vm_cursor, char** tuple_out);

/**
 * @brief Closes a VM cursor, releases all plan nodes, cursors, and handles.
 * @return 0 on success, negative on error.
 */
NT_API int rnt_vm_cursor_close(rnt_cursor_t vm_cursor);

/* ------------------------------------------------------------------ */
/* Memory management                                                    */
/* ------------------------------------------------------------------ */

/** @brief Releases a string allocated by the API. Safe to call with NULL. */
NT_API void rnt_free_string(char* s);

/** @brief Releases a byte buffer allocated by the API. Safe to call with NULL. */
NT_API void rnt_free_bytes(uint8_t* p);

#ifdef __cplusplus
}
#endif
