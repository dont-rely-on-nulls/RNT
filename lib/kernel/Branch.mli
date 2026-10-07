(** A branch state: its multigroups, and under [previous] the state it
    succeeded. Given [evaluators], the stored programs read through it
    run against it. *)
module Make (S : Abstract.Storage.STORAGE) : sig
  type t

  val make :
    ?evaluators:Protocols.Handle.t ->
    S.connection ->
    (Protocols.Handle.t, Concepts.Condition.condition) result

  val load :
    ?evaluators:Protocols.Handle.t ->
    S.transaction ->
    S.connection ->
    Concepts.Hash.hash ->
    (Protocols.Handle.t, Concepts.Condition.condition) result
end
