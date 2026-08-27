module Make (S : Abstract.Storage.STORAGE) : sig
  type t

  val load : S.transaction -> S.connection -> string -> Concepts.Hash.hash -> (Protocols.Handle.t, Concepts.Condition.condition) result
end
