type batch =
  {tuples: Concepts.Tuple.t BatFingerTree.t; exhausted: bool}

type t

class type implementation = object
  method fetch : int -> (batch, Concepts.Condition.condition) result
end

val make : #implementation -> Handle.protocol
val from : Handle.t -> t Handle.interface option
val require : Handle.t -> (t Handle.interface, Concepts.Condition.condition) result
val fetch : t Handle.interface -> int -> (batch, Concepts.Condition.condition) result

val next : t Handle.interface -> (Concepts.Tuple.t option, Concepts.Condition.condition) result

val drain :
  t Handle.interface ->
  ?limit:int ->
  unit ->
  (Concepts.Tuple.t BatFingerTree.t, Concepts.Condition.condition) result
