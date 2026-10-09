type t
type violations = (string * Concepts.Tuple.t list) list

class type implementation = object
  method check : (violations, Concepts.Condition.condition) result
end

val make : #implementation -> Handle.protocol
val from : Handle.t -> t Handle.interface option
val require : Handle.t -> (t Handle.interface, Concepts.Condition.condition) result
val check : t Handle.interface -> (violations, Concepts.Condition.condition) result
