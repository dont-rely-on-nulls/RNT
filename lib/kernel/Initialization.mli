module Make (S : Abstract.Storage.STORAGE) : sig
  val initialize :
    ?evaluators:(string * Protocols.Handle.t) list ->
    S.connection ->
    (Protocols.Handle.t, Concepts.Condition.condition) result
end
