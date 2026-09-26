type t

class type implementation = object
  method update : string -> Handle.t option -> (Handle.t, Concepts.Condition.condition) result
end

val make : #implementation -> Handle.protocol
val from : Handle.t -> t Handle.interface option

val update :
  t Handle.interface ->
  string ->
  Handle.t option ->
  (t Handle.interface, Concepts.Condition.condition) result
