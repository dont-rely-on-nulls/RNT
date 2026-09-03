module Make (S : Abstract.Storage.STORAGE) : sig
  type t

  val make : S.connection -> (Protocols.Handle.t, Concepts.Condition.condition) result
  val load : S.transaction -> S.connection -> Concepts.Hash.hash -> (Protocols.Handle.t, Concepts.Condition.condition) result
end
