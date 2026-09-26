type t

class type implementation = object
  method predicate : (Concepts.Hash.hash option, Concepts.Condition.condition) result
  method local_constraints : (Concepts.Hash.hash option, Concepts.Condition.condition) result
  method contains : Concepts.Tuple.t -> (bool, Concepts.Condition.condition) result
end

val make : #implementation -> Handle.protocol
val from : Handle.t -> t Handle.interface option
val require : Handle.t -> (t Handle.interface, Concepts.Condition.condition) result

val predicate :
  t Handle.interface -> (Concepts.Hash.hash option, Concepts.Condition.condition) result

val local_constraints :
  t Handle.interface -> (Concepts.Hash.hash option, Concepts.Condition.condition) result

val contains : t Handle.interface -> Concepts.Tuple.t -> (bool, Concepts.Condition.condition) result
