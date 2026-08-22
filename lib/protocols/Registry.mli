type t

class type implementation = object
  method register : string -> Handle.t -> (unit, Concepts.Condition.condition) result
  method unregister : string -> (unit, Concepts.Condition.condition) result
end

val make : implementation -> Handle.protocol

val from : Handle.t -> t Handle.interface option

val register : t Handle.interface -> string -> Handle.t -> (unit, Concepts.Condition.condition) result
val unregister : t Handle.interface -> string -> (unit, Concepts.Condition.condition) result
