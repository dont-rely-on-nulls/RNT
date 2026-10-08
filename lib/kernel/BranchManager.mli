(** The heads of the branches, persisted under [label]. Branches it hands
    out run their stored programs by the evaluators under [root]. *)
module Make (S : Abstract.Storage.STORAGE) : sig
  val make :
    ?root:Protocols.Handle.t ->
    S.connection ->
    string ->
    (Protocols.Handle.t, Concepts.Condition.condition) result
end
