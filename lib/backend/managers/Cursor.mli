type descriptor =
  | Stored of {merkle_root: string}
  | Ephemeral of {merkle_root: string; dependencies: string BatFingerTree.t}

module Make (Store : Abstract.Storage.STORAGE) : sig
  type cursor

  val open_ :
    Store.transaction ->
    descriptor ->
    args:Concepts.Value.value BatFingerTree.t ->
    (cursor, Concepts.Condition.condition) result

  val next : cursor -> (Concepts.Tuple.t option, Concepts.Condition.condition) result
  val close : cursor -> unit
end
