(** a relation computed from other relations. [within] gives the same
    relation read against another directory of relations, so a snapshot
    of the tree can hand out its derived relations as they were, or as
    they would be, at that moment. *)
type t

class type implementation = object
  method within : Handle.t -> (Handle.t, Concepts.Condition.condition) result
end

val make : #implementation -> Handle.protocol
val from : Handle.t -> t Handle.interface option
val within : t Handle.interface -> Handle.t -> (Handle.t, Concepts.Condition.condition) result
