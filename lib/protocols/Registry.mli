type t

class type implementation = object
  method update : string -> Handle.t option -> Handle.t option -> (bool, Concepts.Condition.condition) result
end

val make : #implementation -> Handle.protocol

val from : Handle.t -> t Handle.interface option

val update : t Handle.interface -> string -> Handle.t option -> Handle.t option -> (bool, Concepts.Condition.condition) result
