type state = {branch: string; snapshot: Concepts.Hash.hash}
type t

class type implementation = object
  method state : state
  method pin : state -> unit
end

val make : #implementation -> Handle.protocol
val from : Handle.t -> t Handle.interface option
val require : Handle.t -> (t Handle.interface, Concepts.Condition.condition) result
val state : t Handle.interface -> state
val pin : t Handle.interface -> state -> unit
