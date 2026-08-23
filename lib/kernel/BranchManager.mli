module Make (S : Abstract.Storage.STORAGE) : sig
  val make : S.connection -> string -> (Protocols.Handle.t, Concepts.Condition.condition) result
end
