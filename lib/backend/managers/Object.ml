type multigroup = {merkle_root: string}
type relation = {merkle_root: string}
type ephemeral_relation = {merkle_root: string; dependencies: string BatFingerTree.t}
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

type registry = {reference_count: int; handle_count: int; entry: rnt_object}

(*
  /system/branch/branch1/multigrop/multigroup1/relation/relation1
  /system/branch1/multigrop/multigroup1/relation/relation2
  /system/branch1/multigrop/multigroup1/ephemeral_relation/ephemeral_relation1
  /system/transaction/xyz_txn
 *)

type rnt_object_tree = {data: registry; subsequent: rnt_object_tree BatMap.String.t}

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
            { data= {reference_count= 0; handle_count= 0; entry= object'};
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
  insert path tree

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
  remove path tree
