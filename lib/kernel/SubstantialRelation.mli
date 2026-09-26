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
    S.transaction -> t -> Concepts.Tuple.t -> (t, Concepts.Condition.condition) result

  val contains_tuple :
    S.transaction -> t -> Concepts.Tuple.t -> (bool, Concepts.Condition.condition) result

  val schema_of :
    S.transaction ->
    t ->
    (Protocols.Schematics.relation_description, Concepts.Condition.condition) result

  val enumerate : S.connection -> t -> (Protocols.Handle.t, Concepts.Condition.condition) result
end
