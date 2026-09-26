type t

class type implementation = object
  method enumerate : (Handle.t, Concepts.Condition.condition) result
end

val make : #implementation -> Handle.protocol
val from : Handle.t -> t Handle.interface option
val require : Handle.t -> (t Handle.interface, Concepts.Condition.condition) result
val enumerate : t Handle.interface -> (Handle.t, Concepts.Condition.condition) result
