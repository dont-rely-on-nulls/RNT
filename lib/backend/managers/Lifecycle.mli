module Make (Store : Abstract.Storage.STORAGE) : sig
  type tree = Object.rnt_object_tree

  val monitor : tree -> Concepts.Path.t -> tree
  val pin : tree -> Concepts.Path.t -> tree
  val is_eligible_for_gc : tree -> Concepts.Path.t -> bool
  val contention : tree -> Concepts.Path.t -> bool

  val unmonitor :
    Store.transaction -> tree -> Concepts.Path.t -> (tree, Concepts.Condition.condition) result

  val unpin :
    Store.transaction -> tree -> Concepts.Path.t -> (tree, Concepts.Condition.condition) result

  val collect :
    Store.transaction -> tree -> Concepts.Path.t -> (tree, Concepts.Condition.condition) result
end
