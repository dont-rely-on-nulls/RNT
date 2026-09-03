class type implementation = object
  method heading : (Concepts.Hash.hash, Concepts.Condition.condition) result
  method predicate : (Concepts.Hash.hash option, Concepts.Condition.condition) result
  method local_constraints : (Concepts.Hash.hash option, Concepts.Condition.condition) result
  method tuples : (Concepts.Hash.hash, Concepts.Condition.condition) result
  method contains : Concepts.Blob.t -> (bool, Concepts.Condition.condition) result
end

type Handle.protocol += Relation of implementation
type t = implementation

let make impl = Relation (impl :> implementation)
let from handle = Handle.into handle (function Relation impl -> Some impl | _ -> None)
let heading i = Handle.invoke i (fun o -> o#heading)
let predicate i = Handle.invoke i (fun o -> o#predicate)
let local_constraints i = Handle.invoke i (fun o -> o#local_constraints)
let tuples i = Handle.invoke i (fun o -> o#tuples)
let contains i tuple = Handle.invoke i (fun o -> o#contains tuple)
