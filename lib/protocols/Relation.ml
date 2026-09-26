module Error = struct
  open Concepts.Condition

  let not_a_relation () =
    condition "not-a-relation" "A handle was expected to carry the relation protocol and did not"
      empty
end

class type implementation = object
  method contains : Concepts.Tuple.t -> (bool, Concepts.Condition.condition) result
end

type Handle.protocol += Relation of implementation
type t = implementation

let make impl = Relation (impl :> implementation)
let from handle = Handle.into handle (function Relation impl -> Some impl | _ -> None)
let require handle = from handle |> Option.to_result ~none:(Error.not_a_relation ())
let contains i tuple = Handle.invoke i (fun o -> o#contains tuple)
