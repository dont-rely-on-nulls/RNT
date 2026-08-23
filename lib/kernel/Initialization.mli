module Make (S : Abstract.Storage.STORAGE) : sig
  val initialize : S.connection -> (Protocols.Handle.t, Concepts.Condition.condition) result
end
