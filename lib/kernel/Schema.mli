(** A schema: its relations, \schema\[s]\relation\[r]. For now only a
    namespace for them. *)
module Make (S : Abstract.Storage.STORAGE) : sig
  include Merkle.VALUE

  val load :
    ?bind:EphemeralRelation.binding ->
    S.connection ->
    t ->
    (Protocols.Handle.t, Concepts.Condition.condition) result

  (** a schema handed over with no address, as a directory holding its
      relations under \relation, to store once the write has begun. A
      relation with no address is stored as a program if it is one, and
      as the tuples it holds if not. *)
  val admit :
    string ->
    Protocols.Handle.t ->
    (S.transaction Prototype.Associative.admission, Concepts.Condition.condition) result

  (** an empty one, stored. *)
  val make : S.connection -> (Protocols.Handle.t, Concepts.Condition.condition) result
end
