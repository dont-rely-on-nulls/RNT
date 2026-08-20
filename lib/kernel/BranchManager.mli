module Make (S : Abstract.Storage.STORAGE) : sig
  type manager

  val initialize : S.connection -> string -> (manager, Concepts.Condition.condition) result
  val fetch : manager -> string -> (Concepts.Hash.hash option, Concepts.Condition.condition) result
  val update : manager -> string -> Concepts.Hash.hash -> Concepts.Hash.hash -> (unit, Concepts.Condition.condition) result

  (* TODO: fork, join *)
end
