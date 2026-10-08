type t

class type implementation = object
  method contains : Concepts.Tuple.t -> (bool, Concepts.Condition.condition) result
end

val make : #implementation -> Handle.protocol
val from : Handle.t -> t Handle.interface option
val require : Handle.t -> (t Handle.interface, Concepts.Condition.condition) result
val contains : t Handle.interface -> Concepts.Tuple.t -> (bool, Concepts.Condition.condition) result

(** the heading a relation describes itself with. *)
val heading : Handle.t -> (Schematics.relation_description, Concepts.Condition.condition) result

(** the heading and tuples of a relation, read whole. *)
val read :
  Handle.t ->
  (Schematics.relation_description * Concepts.Tuple.t list, Concepts.Condition.condition) result
