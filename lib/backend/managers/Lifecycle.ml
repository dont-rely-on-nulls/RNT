(* The lifecycle manager decides when a registered object may leave memory.
   It works purely on the object tree and never touches storage: collection
   here means dropping the in-memory registry entry, not deleting anything on
   disk. Durable-backed objects (relations, multigroups, branch trees) can be
   rebuilt from their encoded form on the next access, so evicting them is
   safe and keeps memory bounded. Runtime-only objects (sessions, and later
   transactions) have no durable form, so their collection is a real teardown;
   the manager surfaces those to the caller as disposals rather than acting on
   storage itself. *)

type tree = Object.rnt_object_tree

(* A runtime object that was collected and now needs an external teardown the
   lifecycle manager cannot perform on its own: closing a session, and later
   rolling back a transaction. The caller drains these after a collect. *)
type disposal = {path: Concepts.Path.t; kind: Object.rnt_object_kind}

let monitor (tree : tree) (path : Concepts.Path.t) : tree =
  Object.update path (fun r -> {r with Object.handle_count= r.Object.handle_count + 1}) tree

(* Pin is an explicit keep-alive that bypasses collection. It does not touch
   reference_count: pinning is a decision, reference counting is bookkeeping of
   real edges. Keeping them separate is what stops the two from being mistaken
   for each other. *)
let pin (tree : tree) (path : Concepts.Path.t) : tree =
  Object.update path (fun r -> {r with Object.pinned= true}) tree

let unpin (tree : tree) (path : Concepts.Path.t) : tree =
  Object.update path (fun r -> {r with Object.pinned= false}) tree

(* An object may be collected only when nothing holds it open, nothing depends
   on it, it has not been pinned, and its kind is not exempt (a branch). This
   works on the registry record directly so callers that already hold it (the
   cascade) need not walk the tree a second time. *)
let registry_eligible (r : Object.registry) : bool =
  r.Object.handle_count = 0
  && r.Object.reference_count = 0
  && (not r.Object.pinned)
  && not (Object.is_gc_exempt r.Object.entry.Object.kind)

let is_eligible_for_gc (tree : tree) (path : Concepts.Path.t) : bool =
  match Object.find path tree with Some r -> registry_eligible r | None -> false

(* Contention reports whether a mutation must wait. An exclusive object with an
   open handle, such as a branch head being read, cannot be modified until the
   handle closes. This gates writers; it is not part of collection. *)
let contention (tree : tree) (path : Concepts.Path.t) : bool =
  match Object.find path tree with
  | Some r -> r.Object.entry.Object.exclusive && r.Object.handle_count > 0
  | None -> false

(* Cascade the collection at path, threading the pruned tree and the disposals
   gathered so far. Disposals are prepended (never appended), so the recursion
   stays linear; the public entry points reverse once to hand back parent-first,
   left-to-right order.

   Order of teardown falls out of the counts. Collecting an object drops the
   reference_count of every input it depended on (Object.unregister undoes the
   edges), which can make those inputs eligible in turn, so we recurse into
   them. A populated namespace is kept, not collected and not an error: it is
   scaffolding for the objects still living under it. *)
let rec cascade (tree : tree) (disposals : disposal list) (path : Concepts.Path.t) :
    (tree * disposal list, Concepts.Condition.condition) result =
  match Object.find path tree with
  | None -> Ok (tree, disposals)
  | Some r when not (registry_eligible r) -> Ok (tree, disposals)
  | Some r ->
      let kind = r.Object.entry.Object.kind in
      begin match kind with
      | Object.Namespace _ when Object.has_children path tree -> Ok (tree, disposals)
      | _ ->
          let edges = Object.reference_edges kind in
          let disposals = if Object.is_runtime kind then {path; kind} :: disposals else disposals in
          Result.bind (Object.unregister path tree) (fun tree ->
              BatFingerTree.fold_left
                (fun acc dep -> Result.bind acc (fun (tree, disposals) -> cascade tree disposals dep))
                (Ok (tree, disposals))
                edges )
      end

let try_collect (tree : tree) (path : Concepts.Path.t) :
    (tree * disposal list, Concepts.Condition.condition) result =
  Result.map (fun (tree, disposals) -> (tree, List.rev disposals)) (cascade tree [] path)

(* Close a handle, then see whether the object can now go. *)
let unmonitor (tree : tree) (path : Concepts.Path.t) :
    (tree * disposal list, Concepts.Condition.condition) result =
  let tree =
    Object.update path
      (fun r ->
        if r.Object.handle_count = 0 then r
        else {r with Object.handle_count= r.Object.handle_count - 1} )
      tree
  in
  try_collect tree path

(* Public entry point for an explicit collection request. *)
let collect (tree : tree) (path : Concepts.Path.t) :
    (tree * disposal list, Concepts.Condition.condition) result =
  try_collect tree path

(* Session reaping is not built here yet. A lost connection is detected by a
   per-session inactivity timer whose expiry drives collect on the session.
   Design and tasks are tracked in issue #24. *)
