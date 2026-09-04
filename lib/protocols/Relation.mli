module Cursor : sig
  (** A closeable, one-way stream of tuple payloads. *)
  type t

  val make :
    next:(unit -> (Concepts.Blob.t option, Concepts.Condition.condition) result) ->
    close:(unit -> unit) ->
    t

  (** Return one tuple, end of stream, or a sticky scan failure. *)
  val next : t -> (Concepts.Blob.t option, Concepts.Condition.condition) result

  val close : t -> unit
end

type t

class type implementation = object
  method heading : (Concepts.Hash.hash, Concepts.Condition.condition) result
  method predicate : (Concepts.Hash.hash option, Concepts.Condition.condition) result
  method local_constraints : (Concepts.Hash.hash option, Concepts.Condition.condition) result
  method tuples : (Concepts.Hash.hash, Concepts.Condition.condition) result
  method contains : Concepts.Blob.t -> (bool, Concepts.Condition.condition) result
  method enumerate : Cursor.t
end

val make : #implementation -> Handle.protocol
val from : Handle.t -> t Handle.interface option
val heading : t Handle.interface -> (Concepts.Hash.hash, Concepts.Condition.condition) result

val predicate :
  t Handle.interface -> (Concepts.Hash.hash option, Concepts.Condition.condition) result

val local_constraints :
  t Handle.interface -> (Concepts.Hash.hash option, Concepts.Condition.condition) result

val tuples : t Handle.interface -> (Concepts.Hash.hash, Concepts.Condition.condition) result
val contains : t Handle.interface -> Concepts.Blob.t -> (bool, Concepts.Condition.condition) result

(** Start a fresh lazy scan over the relation's asserted tuples. *)
val enumerate : t Handle.interface -> Cursor.t
