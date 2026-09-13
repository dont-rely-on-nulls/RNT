module Error = struct
  open Concepts.Condition

  let not_enumerable () =
    condition "not-enumerable"
      "A relation was used where the expression must iterate its members, but it does not support \
       enumeration. A procedural relation may decide membership without being able to produce it."
      empty
end

class type implementation = object
  method enumerate : Context.t -> (Handle.t, Concepts.Condition.condition) result
end

type Handle.protocol += Enumerable of implementation
type t = implementation

let make impl = Enumerable (impl :> implementation)
let from handle = Handle.into handle (function Enumerable impl -> Some impl | _ -> None)
let require handle = from handle |> Option.to_result ~none:(Error.not_enumerable ())
let enumerate i context = Handle.invoke i (fun o -> o#enumerate context)
