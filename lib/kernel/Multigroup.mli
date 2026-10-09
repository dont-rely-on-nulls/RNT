(** A multigroup: its schemas, \multigroup\[m]\schema\[s], and its denials,
    \multigroup\[m]\denial\[d]. *)
module Make (S : Abstract.Storage.STORAGE) : sig
  include Merkle.VALUE

  val load :
    ?bind:EphemeralRelation.binding ->
    S.connection ->
    t ->
    (Protocols.Handle.t, Concepts.Condition.condition) result

  (** a multigroup handed over with no address, as a directory holding its
      schemas under \schema and its denials under \denial, to store once the
      write has begun. *)
  val admit :
    string ->
    Protocols.Handle.t ->
    (S.transaction Prototype.Associative.admission, Concepts.Condition.condition) result

  (** an empty one, stored. *)
  val make : S.connection -> (Protocols.Handle.t, Concepts.Condition.condition) result
end
