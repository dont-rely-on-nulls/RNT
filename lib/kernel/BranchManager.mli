(** The heads of the branches, persisted under [label]. Branches it hands
    out run their stored programs through [evaluators]. *)
module Make (S : Abstract.Storage.STORAGE) : sig
  val make :
    ?evaluators:Protocols.Handle.t ->
    S.connection ->
    string ->
    (Protocols.Handle.t, Concepts.Condition.condition) result
end
