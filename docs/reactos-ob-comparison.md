# ReactOS Object Manager — Insights for RelationalNT

A comparative study of the ReactOS kernel object manager (`ntoskrnl/ob`) against
the RelationalNT runtime, identifying structural patterns from the OS kernel that
translate directly into improvements for a database kernel.

The ReactOS OB is roughly 8,000 lines across `oblife.c`, `obhandle.c`, `obref.c`,
`obdir.c`, `obname.c`, and `obsecure.c`. The notes below focus on the subset of
patterns that have a clear database analogue, with adjustments for the
immutable-storage model this project uses.

---

## 1. Two-Level Reference Counting

**ReactOS pattern.** Every object header carries two independent counters:
`PointerCount` (kernel-internal references, e.g. a driver holding a pointer) and
`HandleCount` (external user-visible handles). Object deletion only proceeds when
*both* reach zero.

**Database analogue.** RelationalNT already has `reference_count` and
`handle_count` in `registry_head`, but `reference_count` is unimplemented (see
`ObjectManager.h` TODO). The two counters serve different purposes and must be
decremented by different paths:

- `handle_count` — open sessions holding a cursor or handle on this object.
  Managed by `LifecycleManager::Monitor` / `Unmonitor`.
- `reference_count` — structural dependencies: a view referencing its base
  relations, an index depending on a relation's schema. Managed by a separate
  `Pin` / `Unpin` pair.

An object may only be garbage-collected when both counters reach zero.
`Unmonitor` should trigger GC only after checking `reference_count == 0`.
Without this, there is no safe way to remove a RELATION that still backs a view.

**Important note on snapshots.** Snapshots in this system are *always immutable*.
Every insertion or deletion produces a new snapshot version of the multigroup
rather than mutating the existing one. A snapshot is therefore not a special
lifecycle category — it is just another registered object. Its `reference_count`
is non-zero while any cursor is pinned to it, and the snapshot is eligible for
removal only when that count drops to zero. The object flag classification
(permanent vs. non-permanent) applies to *schema objects*, not to snapshot
versions.

**TODOs:** `LifecycleManager` — add `Pin(registry*)` / `Unpin(registry*)`.
`LifecycleManager::Unmonitor` — check both counters before triggering GC.

---

## 2. Type Callbacks Instead of a Method Set

**ReactOS pattern.** Object types register actual function pointers:
`OpenProcedure`, `CloseProcedure`, `DeleteProcedure`, `ParseProcedure`,
`SecurityProcedure`. The kernel calls into the type-specific callback rather than
branching on a type enum.

**Database analogue.** `object_type::methods` is currently a `std::set<METHOD>`
that `IdentityManager::CanOpen` checks against but never acts on. Replacing the
set with typed callbacks eliminates the identity manager as a separate component
and makes object behaviour self-contained:

| Callback | Database use |
|---|---|
| `OpenProcedure` | RELATION — acquire snapshot pin, register with LifecycleManager |
| `CloseProcedure` | TRANSACTION — auto-rollback if no explicit commit was issued |
| `DeleteProcedure` | MULTIGROUP — cascade to relations |
| `ParseProcedure` | View/alias entry — reparse to the physical relation's path (see §8) |

**Debuggability concern.** Function pointers are harder to trace than a named
path through the identity manager. Mitigation: store the callback alongside a
`const char* name` label in `object_type` so that logs and assertions can
identify which callback fired. A `std::function` with a wrapper that records the
type label before dispatching also works.

**Security constraint on ParseProcedure.** When a view (an ephemeral RELATION
whose `ParseProcedure` reparses to base relations) is resolved, the capability
check must be evaluated against the *view's* security descriptor, not the base
relations'. A caller who holds READ on the view must *not* gain the ability to
open handles directly on the underlying relations — those require explicit
permissions of their own. The ParseProcedure reparse mechanism navigates
internally through the namespace on behalf of the runtime; it does not grant the
caller a transitive handle on the base object. The resolved handle is bound to the
view, and the base relations are accessed only via the view's own type callbacks.

**TODOs:** `ObjectManager::object_type` — replace `std::set<METHOD> methods` with
typed callback fields. `IdentityManager` — migrate to invoke `OpenProcedure` /
`CloseProcedure`; the manager becomes a thin dispatcher or is absorbed into
`HandlerManager`.

---

## 3. Hash Directory / Trie for Object Lookup

**ReactOS pattern.** Each `OBJECT_DIRECTORY` holds a 37-bucket hash table (37 is
prime, chosen to reduce clustering). Name resolution walks path components
one-by-one, locking each directory, hashing the component, and following
collision chains. A found entry is moved to the head of its bucket (MRU
optimisation).

**Current state.** `ObjectManager::Find` is an O(n) linear scan of a linked list.
The code comment already says "treat as a list for now, but ideally it is a tree."

**Recommended approach.** Replace the flat list with a trie whose nodes are
directories keyed by path segment. Each directory node holds a hash map from
segment string to child `registry*`. This matches the ReactOS structure naturally
because `object_path` is already a `std::vector<std::string>`.

Rather than implementing the trie from scratch, consider pulling a suitable
container via the Nix flake (e.g. a radix tree or a well-tested associative structure).
The only hard requirement is that each directory level supports O(1) average
lookup by segment name and ordered iteration for namespace enumeration.

**TODO:** `ObjectManager` — replace `std::unique_ptr<registry> entries` (linked
list) with a trie or per-level hash map. `ObjectManager::Find` and `Register`
both need to be updated.

---

## 4. Per-Handle Access Mask

**ReactOS pattern.** The handle table entry stores `GrantedAccess` per handle, not
per object. A single object can be opened read-only by one session and read-write
by another simultaneously; each handle's access mask is checked independently.

**Database analogue.** `HandlerManager::handle` currently holds only `object*`
and `void* connection_context`. Adding `std::set<AUTH_CLAIM> granted_access`
enables the access mask to be evaluated once at `Open` time and cached in the
handle for the duration of the session. This resolves the open performance
question in `PermissionsManager` ("undecided whether to check on every access or
cache").

**Immutable storage note.** In this system, storage is append-only. A WRITE claim
does not mean mutating an existing tuple in-place; it means the session is
authorised to produce a new snapshot version of the relation. The access mask
semantics should be read accordingly: READ grants access to query an existing
snapshot; WRITE grants access to commit a new one. Two sessions holding WRITE
handles on the same relation produce independent snapshots — there is no conflict
at the storage level.

**TODO:** `HandlerManager::handle` — add `std::set<AUTH_CLAIM> granted_access`.
`HandlerManager::Open` — populate it from `PermissionsManager::Firewall` /
`Access` and store in the handle. Subsequent checks read from the handle rather
than re-evaluating the security descriptor.

---

## 5. Capability-Based Security, No Inheritance

**ReactOS pattern.** ReactOS supports SD inheritance through directory traversal:
an object can inherit its parent directory's security descriptor if none is
explicitly set.

**This project does not use SD inheritance.** Permissions here are strictly
capability-based and must be explicitly granted. There is no implicit flow of
access rights from a multigroup down to its constituent relations. A caller who
holds READ on `/multigroups/coffee_shop` does not thereby hold READ on
`/multigroups/coffee_shop/relations/user` — that is a separate, explicit
capability.

This is a deliberate departure from the ReactOS model, and it is the correct
design for a database where row-level and column-level access policies are
common. The capability tree in `PermissionsManager` is the authoritative
source of truth; the namespace hierarchy is purely organisational.

**Implication for the SD cache.** When a shared security descriptor cache is
added (see §7 of the original notes), descriptors must be deduplicated by
content, not by ancestry. Two unrelated relations that happen to have identical
ACLs may share a cached SD; that sharing is a performance optimisation, not a
statement about inheritance.

---

## 6. Mutable Reference Contention (Branch HEAD)

**ReactOS pattern.** `OB_FLAG_EXCLUSIVE` on an object header prevents more than
one handle from being open simultaneously. The flag is checked during
`ObpCreateHandle`; a second opener fails immediately.

**Database analogue.** `LifecycleManager::Contention` is a stub that always
returns `true`. It needs to distinguish:

- **Immutable objects (RELATION snapshots, MULTIGROUP snapshots, TRANSACTION)** —
  contention is never raised. These are content-addressed and append-only; two
  sessions opening the same snapshot independently is fine.
- **Mutable reference states (branch HEAD, namespace entries)** — contention must
  be enforced. A branch HEAD is the only mutable pointer in the system; it needs
  single-writer semantics. When a session holds a write handle on a HEAD, a second
  writer must block or fail.

The contention check belongs on the *reference object* (the HEAD pointer), not on
the snapshot object it points to. This maps cleanly to ReactOS's exclusive flag:
add an `exclusive` flag to `object_type` (or a dedicated flag on `registry_head`)
that Contention() checks.

**Note on session parallelism.** Because storage is immutable, two sessions
writing to the same relation in parallel always produce separate, independent
snapshots. There is no write-write conflict at the data level. The only genuine
contention point is advancing a branch HEAD — the moment where one of the
competing snapshots must be chosen as the new tip. This is the correct and narrow
scope for Contention().

**TODOs:** `ObjectManager::registry_head` or `object_type` — add `bool exclusive`
flag. `LifecycleManager::Contention` — implement: return false immediately for
non-exclusive objects; for exclusive objects, return false if `handle_count > 0`
for a write-mode opener.

---

## 7. Deferred Deletion / Asynchronous GC

**ReactOS pattern.** When an object's pointer count reaches zero, ReactOS does not
delete it inline. It appends to a lock-free `NextToFree` linked list and posts a
work item to a reaper thread (`ObpReapObject`). This keeps deletion latency off
the hot path and prevents stack overflow in nested deletes.

**Database relevance.** Snapshot compaction and history pruning are expensive
operations that should not run inline inside a client-facing `Close()`. The reaper
pattern maps to a background GC worker: `Unmonitor` enqueues the object when both
counters reach zero; the GC thread drains the queue and calls the type's
`DeleteProcedure`.

This is noted for completeness. **Compaction is out of scope for the current
implementation phase.** Record it here so the architecture accommodates it:
`LifecycleManager::Unmonitor` should eventually enqueue rather than immediately
free.

---

## 8. NamespaceReferenceManager as the Reparse Layer

**ReactOS pattern.** `ParseProcedure` on a type can return `STATUS_REPARSE` with
a new path, causing the name resolver to restart from the new path. Symbolic links
use this. The resolver caps reparse at 30 iterations to detect cycles.

**This is the right architecture for `NamespaceReferenceManager`.** The manager
currently has no implementation. It should be built around the same concept:

- **Branch references** — a path like `/refs/branch/main` is a namespace entry
  whose `ParseProcedure` returns a reparse pointing to the actual snapshot path
  (e.g. `/snapshots/abc123`). The caller's handle lands on the snapshot, not on
  the reference object itself, unless the caller explicitly opens the reference
  object for writing (to advance the HEAD).

- **View resolution** — a view's `ParseProcedure` reparses to its base relations
  internally, subject to the capability security constraint in §2: the reparse
  happens inside the runtime; the caller's handle and access mask stay bound to
  the view.

- **Atomic multi-reference updates** — pushing to both `main` and `audit_log`
  must be all-or-nothing. The implementation should acquire exclusive locks on all
  involved namespace entries before updating any of them. If a Contention() check
  fails on any entry, release all locks and abort the batch. This preserves audit
  consistency.

- **Cycle guard** — view definitions may reference other views. Name resolution
  must track reparse depth and fail with an error after a bounded number of
  iterations (30 is the ReactOS figure; a similar constant is appropriate here).

- **Audit branch** — audit is a write concern that spans all branches. It should
  be modelled as an independent branch whose HEAD is the only contention point for
  audit-affecting operations, dissociated from the data branch scope.

**TODOs:** `NamespaceReferenceManager` — implement `Resolve(path)` with reparse
loop and cycle guard. Define the reference object type with an `exclusive` flag
and a `ParseProcedure` that rewrites the path. Define the batch-update API with
all-or-nothing semantics.

---

## Priority Order

| Priority | Item | Header(s) affected |
|---|---|---|
| 1 | Dual ref counting — implement `Pin` / `Unpin` | `LifecycleManager.h` |
| 2 | Type callbacks — replace `methods` set with function pointers | `ObjectManager.h`, `IdentityManager.h` |
| 3 | Per-handle access mask | `HandlerManager.h` |
| 4 | Exclusive flag → real `Contention()` for branch HEADs | `ObjectManager.h`, `LifecycleManager.h` |
| 5 | Trie / hash directory for `ObjectManager::Find` | `ObjectManager.h` |
| 6 | `NamespaceReferenceManager` reparse layer | `NamespaceReferenceManager.h` |
| 7 | Shared SD cache (no inheritance, content-addressed) | `PermissionsManager.h` |
| 8 | Deferred GC queue in `Unmonitor` | `LifecycleManager.h` |
