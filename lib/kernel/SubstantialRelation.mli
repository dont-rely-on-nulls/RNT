module Make (S : Abstract.Storage.STORAGE) : sig
  type t

  val encode : t -> Concepts.Blob.t
  val decode : Concepts.Blob.t -> (t, Concepts.Condition.condition) result

  val empty :
    S.transaction ->
    schematics:Concepts.Hash.hash ->
    ?predicate:Concepts.Hash.hash ->
    ?local_constraints:Concepts.Hash.hash ->
    ?indexes:Concepts.Hash.hash ->
    unit ->
    (t, Concepts.Condition.condition) result

  val store : S.transaction -> t -> (Concepts.Hash.hash, Concepts.Condition.condition) result

  val make :
    S.connection ->
    schematics:Concepts.Hash.hash ->
    ?predicate:Concepts.Hash.hash ->
    ?local_constraints:Concepts.Hash.hash ->
    ?indexes:Concepts.Hash.hash ->
    unit ->
    (Protocols.Handle.t, Concepts.Condition.condition) result

  val load_value : S.transaction -> Concepts.Hash.hash -> (t, Concepts.Condition.condition) result

  val wrap : S.connection -> t -> (Protocols.Handle.t, Concepts.Condition.condition) result

  val load :
    S.transaction ->
    S.connection ->
    Concepts.Hash.hash ->
    (Protocols.Handle.t, Concepts.Condition.condition) result

  val schematics : t -> Concepts.Hash.hash
  val predicate : t -> Concepts.Hash.hash option
  val local_constraints : t -> Concepts.Hash.hash option
  val tuples : t -> Concepts.Hash.hash
  val indexes : t -> Concepts.Hash.hash option
  val hash : t -> Concepts.Hash.hash

  val assert_tuple :
    S.transaction -> t -> Concepts.Blob.t -> (t, Concepts.Condition.condition) result

  val contains_tuple :
    S.transaction -> t -> Concepts.Blob.t -> (bool, Concepts.Condition.condition) result

  (** decodes the schematics at [schematics relation] -- the body of
      [Protocols.Schematics.describe] for this kind of relation. *)
  val schema_of :
    S.transaction ->
    t ->
    (Protocols.Schematics.relation_description, Concepts.Condition.condition) result

  (** a handle carrying [Protocols.Cursor] over every tuple currently
      asserted, decoded via [Concepts.Tuple.Representation.of_blob] --
      the body of [Protocols.Relation.enumerate] for this kind of
      relation. Opens its own storage transaction, held for the
      cursor's whole lifetime rather than just this call -- see
      [Kernel.Generator] and docs/design/evaluator.md, "Shape". *)
  val enumerate : S.connection -> t -> (Protocols.Handle.t, Concepts.Condition.condition) result
end
