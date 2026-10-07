module Make (S : Abstract.Storage.STORAGE) : sig
  (** the root of the object tree, holding only \system: its branches,
      the [evaluators] by language, the sessions and the applications. *)
  val initialize :
    ?evaluators:(string * Protocols.Handle.t) list ->
    S.connection ->
    (Protocols.Handle.t, Concepts.Condition.condition) result

  (** give a subsystem a root of its own, \[name], with branches of its
      own whose heads are kept apart from every other root's. Its stored
      programs run through \system\evaluator. *)
  val mount :
    S.connection ->
    Protocols.Handle.t ->
    string ->
    (Protocols.Handle.t, Concepts.Condition.condition) result
end
