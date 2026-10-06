(** relations as values a subsystem hands to the tree. *)

type heading = Protocols.Schematics.attribute_description BatMap.String.t
type rows = (Concepts.Tuple.t list, Concepts.Condition.condition) result

(** a relation holding [tuples], which never changes. *)
val fixed : heading -> Concepts.Tuple.t list -> Protocols.Handle.t

(** a relation computed from a directory of relations. Read as it is, it
    is computed against [current ()] each time; read through a snapshot,
    it is computed against the snapshot instead (see [Protocols.Derived]),
    so it is what it was, or would be, at that moment. *)
val computed :
  heading ->
  current:(unit -> (Protocols.Handle.t, Concepts.Condition.condition) result) ->
  (Protocols.Handle.t -> rows) ->
  Protocols.Handle.t

(** the heading and tuples of a relation, read whole. *)
val read :
  Protocols.Handle.t -> (heading * Concepts.Tuple.t list, Concepts.Condition.condition) result
