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

type rnt_method = OPEN | CLOSE

type rnt_object =
  {kind: rnt_object_kind; disposable: bool; methods: rnt_method BatSet.t; exclusive: bool}

type registry = {reference_count: int; handle_count: int; entry: rnt_object}

type rnt_object_tree =
  | Intermediary of {label: string; data: registry; subsequent: rnt_object_tree BatFingerTree.t}
  | Final of {label: string; data: registry}

val register : Concepts.Path.t -> rnt_object_tree -> rnt_object -> rnt_object_tree
val find : Concepts.Path.t -> rnt_object_tree -> registry option
val unregister : Concepts.Path.t -> rnt_object_tree -> rnt_object_tree
val update : Concepts.Path.t -> (registry -> registry) -> rnt_object_tree -> rnt_object_tree
val fold : (Concepts.Path.t -> registry -> 'a -> 'a) -> 'a -> rnt_object_tree -> 'a
