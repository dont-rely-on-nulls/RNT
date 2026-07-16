module Make (Store : Abstract.Storage.STORAGE) : sig
  type tree = Object.rnt_object_tree

  val resolve :
    Store.transaction ->
    tree ->
    Concepts.Path.t ->
    (Concepts.Path.t, Concepts.Condition.condition) result
end
