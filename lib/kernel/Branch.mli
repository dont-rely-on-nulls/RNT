(** A branch state: its multigroups, and under [previous] the state it
    succeeded. Given [root], the stored programs read through it run, by
    the evaluators registered under [root], against it. *)
module Make (S : Abstract.Storage.STORAGE) : sig
  type t

  val make : S.connection -> (Protocols.Handle.t, Concepts.Condition.condition) result

  val load :
    ?root:Protocols.Handle.t ->
    S.transaction ->
    S.connection ->
    Concepts.Hash.hash ->
    (Protocols.Handle.t, Concepts.Condition.condition) result
end
