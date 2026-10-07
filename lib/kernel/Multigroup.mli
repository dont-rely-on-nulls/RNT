module Make (S : Abstract.Storage.STORAGE) : sig
  type t

  val encode : t -> Concepts.Blob.t
  val decode : Concepts.Blob.t -> (t, Concepts.Condition.condition) result

  (** [bind] runs the stored programs read through the multigroup; see
      [EphemeralRelation.binding]. *)
  val wrap :
    ?bind:EphemeralRelation.binding ->
    S.connection ->
    t ->
    (Protocols.Handle.t, Concepts.Condition.condition) result

  val make : S.connection -> (Protocols.Handle.t, Concepts.Condition.condition) result
end
