module Error = struct
  open Concepts.Condition

  let not_a_relation () =
    condition "not-a-relation" "A handle was expected to carry the relation protocol and did not"
      empty
end

class type implementation = object
  method predicate : (Concepts.Hash.hash option, Concepts.Condition.condition) result
  method local_constraints : (Concepts.Hash.hash option, Concepts.Condition.condition) result
  method contains : Concepts.Tuple.t -> (bool, Concepts.Condition.condition) result
end

type Handle.protocol += Relation of implementation
type t = implementation

let make impl = Relation (impl :> implementation)
let from handle = Handle.into handle (function Relation impl -> Some impl | _ -> None)
let require handle = from handle |> Option.to_result ~none:(Error.not_a_relation ())
let predicate i = Handle.invoke i (fun o -> o#predicate)
let local_constraints i = Handle.invoke i (fun o -> o#local_constraints)
let contains i tuple = Handle.invoke i (fun o -> o#contains tuple)
