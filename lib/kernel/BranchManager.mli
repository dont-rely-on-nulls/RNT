type branch = string            (* FIXME *)

module Make (S : Abstract.Storage.STORAGE) : sig
  type manager

  val initialize : S.connection -> string -> (manager, Concepts.Condition.condition) result
  val fetch : manager -> string -> (branch option, Concepts.Condition.condition) result
  val update : manager -> string -> (branch -> branch) -> (manager, Concepts.Condition.condition) result

  (* TODO: fork, join *)
end
