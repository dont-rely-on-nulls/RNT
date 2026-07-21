type tree = Object.rnt_object_tree

(* A collected runtime object that still needs an external teardown: a session
   to close, and later a transaction to roll back. The caller drains these. *)
type disposal = {path: Concepts.Path.t; kind: Object.rnt_object_kind}

val monitor : tree -> Concepts.Path.t -> tree
val pin : tree -> Concepts.Path.t -> tree
val unpin : tree -> Concepts.Path.t -> tree
val is_eligible_for_gc : tree -> Concepts.Path.t -> bool
val contention : tree -> Concepts.Path.t -> bool

val unmonitor :
  tree -> Concepts.Path.t -> (tree * disposal BatFingerTree.t, Concepts.Condition.condition) result

val collect :
  tree -> Concepts.Path.t -> (tree * disposal BatFingerTree.t, Concepts.Condition.condition) result
