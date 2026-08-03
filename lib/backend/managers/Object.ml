(* @uses Path -- snoc, to_string when building registry paths *)
(* @uses Condition -- builds registry-object/path errors *)
(* @needs Value *)

type multigroup = {merkle_root: string}
type relation = {merkle_root: string}

(* An ephemeral relation is a stored plan that reads other relations. Its
   dependencies are the inputs that plan replays over. They are branch-local
   symlink paths, not version-pinned paths: as the branch head advances the
   inputs move with it, and Namespace.resolve turns the symlink into whatever
   object is current on this branch hash. Keeping them as paths (not hashes)
   is what lets an ephemeral relation behave like a view. *)
type ephemeral_relation = {merkle_root: string; dependencies: Concepts.Path.t BatFingerTree.t}
type transaction = unit
type session = {connection_context: unit; branch_overrides: string BatMap.String.t}
type branch = {name: string; target_hash: string}
type branch_tree = {merkle_root: string}

type rnt_object_kind =
  | Multigroup of multigroup
  | Relation of relation
  | EphemeralRelation of ephemeral_relation
  | Session of session
  | Branch of branch
  | BranchTree of branch_tree
  | Namespace of namespace

and namespace = {label: string; predicate: rnt_object_kind -> bool}

type rnt_method = OPEN | CLOSE

type rnt_object =
  {kind: rnt_object_kind; disposable: bool; methods: rnt_method BatSet.t; exclusive: bool}

(* Three independent facts about a registered object, kept apart on purpose:

   - handle_count: how many handles are open on it right now (open/close).
   - reference_count: how many other objects depend on it staying resident.
     This is bookkeeping of real edges, nothing more. It goes up because a
     dependency exists, not because someone asked to keep the object alive.
   - pinned: an explicit override that bypasses collection regardless of the
     counts. Used when something must not be evicted even though nothing
     currently points at it or holds it open. This is deliberately separate
     from reference_count so the two reasons never get confused. *)
type registry = {reference_count: int; handle_count: int; pinned: bool; entry: rnt_object}

(*
  /system/branch/branch1/multigrop/multigroup1/relation/relation1
  /system/branch1/multigrop/multigroup1/relation/relation2
  /system/branch1/multigrop/multigroup1/ephemeral_relation/ephemeral_relation1
  /system/transaction/xyz_txn
 *)

type rnt_object_tree = {data: registry; subsequent: rnt_object_tree BatMap.String.t}

module type RUNTIME_STRATEGY = sig
  type 'a state

  (* The exact snapshot observed on acquire *)
  type 'a token

  val create : 'a -> 'a state
  val acquire : 'a state -> 'a * 'a token
  val publish : 'a state -> 'a token -> 'a -> (unit, Concepts.Condition.condition) result
end

module Error = struct
  open Concepts.Condition

  let registry_object_already_registered path =
    let msg = "An object is already registered in the path" in
    condition "registry-object-already-registered" msg
      ("path" |=| Concepts.Value.String (Concepts.Path.to_string path))

  let registry_path_not_found path =
    let msg = "The provided path was not found" in
    condition "registry-path-not-found" msg
      ("path" |=| Concepts.Value.String (Concepts.Path.to_string path))
end

let make_object ?(disposable = false) ?(exclusive = false) ?(methods = BatSet.empty)
    (kind : rnt_object_kind) : rnt_object =
  {kind; disposable; methods; exclusive}

(* The empty registry. The root node is the system namespace itself, and every
   other object is registered under it. Path separators are only a string
   rendering concern, so there is no distinct "/" node above system: system is
   the root. It is exempt from collection for the same reason a branch is, it
   is the way in to everything else. *)
let root : rnt_object_tree =
  { data=
      { reference_count= 0;
        handle_count= 0;
        pinned= false;
        entry= make_object (Namespace {label= "system"; predicate= (fun _ -> true)}) };
    subsequent= BatMap.String.empty }

let find (path : Concepts.Path.t) (tree : rnt_object_tree) : registry option =
  let rec walk components node =
    match BatFingerTree.front components with
    | None -> Some node.data
    | Some (tail, head) -> Option.bind (BatMap.String.find_opt head node.subsequent) (walk tail)
  in
  walk path tree

let update (path : Concepts.Path.t) (f : registry -> registry) (tree : rnt_object_tree) :
    rnt_object_tree =
  let rec walk components node =
    match BatFingerTree.front components with
    | None -> {node with data= f node.data}
    | Some (tail, head) ->
      begin match BatMap.String.find_opt head node.subsequent with
      | None -> node
      | Some child ->
          {node with subsequent= BatMap.String.add head (walk tail child) node.subsequent}
      end
  in
  walk path tree

(* The objects that must stay resident for this object to remain replayable.
   Registering an object bumps the reference_count of each edge target and
   unregistering drops it, so reference counts stay in step with the real
   dependency graph. Only ephemeral relations carry edges today. Which kinds
   grow edges is a per-kind decision, which is why this lives next to the
   registry and not in the lifecycle manager: the object knows its own shape. *)
let reference_edges (kind : rnt_object_kind) : Concepts.Path.t BatFingerTree.t =
  match kind with
  | EphemeralRelation {dependencies; _} -> dependencies
  | Multigroup _ | Relation _ | Session _ | Branch _ | BranchTree _ | Namespace _ ->
      BatFingerTree.empty

(* Adjust the reference_count of every edge target by delta. A target that is
   not present is skipped: update leaves the tree untouched when the path is
   missing. That is fine for a skeleton, but it hides a dangling dependency,
   so registration will eventually want to fail loudly on a missing input. *)
let adjust_references (delta : int) (paths : Concepts.Path.t BatFingerTree.t)
    (tree : rnt_object_tree) : rnt_object_tree =
  BatFingerTree.fold_left
    (fun tree path ->
      update path (fun r -> {r with reference_count= r.reference_count + delta}) tree )
    tree paths

(* A branch is exempt from collection because everything is reachable through
   it: collecting a branch would orphan its whole subtree. Every other kind is
   collectable, including sessions. A session is runtime-only state with no
   durable encoding, so collecting one is a real teardown rather than an
   eviction, but it still happens (see Lifecycle for how a dead session is
   detected). *)
let is_gc_exempt (kind : rnt_object_kind) : bool = match kind with Branch _ -> true | _ -> false

(* Runtime-only kinds have no durable encoding, so collecting them cannot be
   undone by rehydrating from disk. The lifecycle manager surfaces these to
   its caller as disposals to run (a session close, and later a transaction
   rollback once transactions become objects in their own right). *)
let is_runtime (kind : rnt_object_kind) : bool = match kind with Session _ -> true | _ -> false

let has_children (path : Concepts.Path.t) (tree : rnt_object_tree) : bool =
  let rec walk components node =
    match BatFingerTree.front components with
    | None -> not (BatMap.String.is_empty node.subsequent)
    | Some (tail, head) ->
      begin match BatMap.String.find_opt head node.subsequent with
      | None -> false
      | Some child -> walk tail child
      end
  in
  walk path tree

(* TODO: This function is not tail call optimized. We ventured with
   the idea of using CPS, but that's not going to solve anything here,
   so the probable best course of action is relying on the growing map
   to carry on the state. This is not a big deal as the structure is
   expected to be small enough to live in memory and these operations
   are relatively uncommon. *)
let register (path : Concepts.Path.t) (object' : rnt_object) (tree : rnt_object_tree) :
    (rnt_object_tree, Concepts.Condition.condition) result =
  let rec insert components node =
    match BatFingerTree.front components with
    | None -> Error (Error.registry_object_already_registered path)
    | Some (tail, head) when BatFingerTree.is_empty tail ->
        if BatMap.String.mem head node.subsequent then
          Error (Error.registry_object_already_registered path)
        else
          let child =
            { data= {reference_count= 0; handle_count= 0; pinned= false; entry= object'};
              subsequent= BatMap.String.empty }
          in
          Ok {node with subsequent= BatMap.String.add head child node.subsequent}
    | Some (tail, head) ->
      begin match BatMap.String.find_opt head node.subsequent with
      | None -> Error (Error.registry_path_not_found path)
      | Some child ->
          Result.map (fun child' ->
              {node with subsequent= BatMap.String.add head child' node.subsequent} )
          @@ insert tail child
      end
  in
  (* On success, record the new object's dependency edges by bumping the
     reference_count of each input it reads. This is the polymorphic part of
     registration: the edge set comes from the object's own kind. *)
  Result.map
    (fun tree -> adjust_references 1 (reference_edges object'.kind) tree)
    (insert path tree)

let with_namespace (parent : Concepts.Path.t) (namespace_label : string)
    (predicate : rnt_object_kind -> bool) (name : string) (object' : rnt_object)
    (tree : rnt_object_tree) : (rnt_object_tree, Concepts.Condition.condition) result =
  let namespace_path = Concepts.Path.snoc parent namespace_label in
  let tree_with_namespace =
    match find namespace_path tree with
    | None ->
        register namespace_path (make_object (Namespace {label= namespace_label; predicate})) tree
    | Some _ -> Ok tree
  in
  Result.bind tree_with_namespace (fun tree ->
      register (Concepts.Path.snoc namespace_path name) object' tree )

let construct_multigroup parent name (mg : multigroup) tree =
  with_namespace parent "multigroup"
    (function Multigroup _ -> true | _ -> false)
    name (make_object (Multigroup mg)) tree

let construct_relation parent name (rel : relation) tree =
  with_namespace parent "relation"
    (function Relation _ -> true | _ -> false)
    name (make_object (Relation rel)) tree

let unregister (path : Concepts.Path.t) (tree : rnt_object_tree) :
    (rnt_object_tree, Concepts.Condition.condition) result =
  (* Read the edges before removing the node so we can undo what register did:
     dropping an object releases its hold on the inputs it depended on. *)
  let edges =
    match find path tree with Some r -> reference_edges r.entry.kind | None -> BatFingerTree.empty
  in
  let rec remove components node =
    match BatFingerTree.front components with
    | None -> Error (Error.registry_path_not_found path)
    | Some (tail, head) when BatFingerTree.is_empty tail ->
        if BatMap.String.mem head node.subsequent then
          Ok {node with subsequent= BatMap.String.remove head node.subsequent}
        else Error (Error.registry_path_not_found path)
    | Some (tail, head) ->
      begin match BatMap.String.find_opt head node.subsequent with
      | None -> Error (Error.registry_path_not_found path)
      | Some child ->
          Result.map (fun child' ->
              {node with subsequent= BatMap.String.add head child' node.subsequent} )
          @@ remove tail child
      end
  in
  Result.map (fun tree -> adjust_references (-1) edges tree) (remove path tree)

module type MANAGER = sig
  type t

  val create : branch_index_root:Concepts.Hash.hash -> registry:rnt_object_tree -> t
  val branch_index_root : t -> Concepts.Hash.hash
  val find : t -> Concepts.Path.t -> registry option

  val update :
    t -> Concepts.Path.t -> (registry -> registry) -> (unit, Concepts.Condition.condition) result

  val register : t -> Concepts.Path.t -> rnt_object -> (unit, Concepts.Condition.condition) result
  val unregister : t -> Concepts.Path.t -> (unit, Concepts.Condition.condition) result

  val with_namespace :
    t ->
    Concepts.Path.t ->
    string ->
    (rnt_object_kind -> bool) ->
    string ->
    rnt_object ->
    (unit, Concepts.Condition.condition) result

  val construct_multigroup :
    t -> Concepts.Path.t -> string -> multigroup -> (unit, Concepts.Condition.condition) result

  val construct_relation :
    t -> Concepts.Path.t -> string -> relation -> (unit, Concepts.Condition.condition) result
end

(* Keep the immutable tree operations above as the implementation core, while
   this functor owns publication of the current photograph. Runtime bootstraps
   the first photograph and exposes this opaque manager to its consumers. *)
module Make (Strategy : RUNTIME_STRATEGY) : MANAGER = struct
  type photograph = {branch_index_root: Concepts.Hash.hash; registry: rnt_object_tree}
  type t = {state: photograph Strategy.state}

  let create ~branch_index_root ~registry = {state= Strategy.create {branch_index_root; registry}}

  let branch_index_root manager =
    let photograph, _ = Strategy.acquire manager.state in
    photograph.branch_index_root

  let find manager path =
    let photograph, _ = Strategy.acquire manager.state in
    find path photograph.registry

  let modify manager transformation =
    let open Utilities.Result in
    let photograph, token = Strategy.acquire manager.state in
    let* next, result = transformation photograph in
    let* () = Strategy.publish manager.state token next in
    Ok result

  let update manager path f =
    modify manager (fun photograph ->
        let registry = update path f photograph.registry in
        Ok ({photograph with registry}, ()) )

  let register manager path object_ =
    modify manager (fun photograph ->
        let open Utilities.Result in
        let* registry = register path object_ photograph.registry in
        Ok ({photograph with registry}, ()) )

  let unregister manager path =
    modify manager (fun photograph ->
        let open Utilities.Result in
        let* registry = unregister path photograph.registry in
        Ok ({photograph with registry}, ()) )

  let with_namespace manager parent namespace_label predicate name object_ =
    modify manager (fun photograph ->
        let open Utilities.Result in
        let* registry =
          with_namespace parent namespace_label predicate name object_ photograph.registry
        in
        Ok ({photograph with registry}, ()) )

  let construct_multigroup manager parent name multigroup =
    modify manager (fun photograph ->
        let open Utilities.Result in
        let* registry = construct_multigroup parent name multigroup photograph.registry in
        Ok ({photograph with registry}, ()) )

  let construct_relation manager parent name relation =
    modify manager (fun photograph ->
        let open Utilities.Result in
        let* registry = construct_relation parent name relation photograph.registry in
        Ok ({photograph with registry}, ()) )
end
