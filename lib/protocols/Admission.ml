module Error = struct
  open Concepts.Condition

  let not_admitting () =
    condition "not-admitting" "A handle was expected to carry the admission protocol and did not"
      empty
end

type violations = (string * Concepts.Tuple.t) list

class type implementation = object
  method check : (violations, Concepts.Condition.condition) result
end

type Handle.protocol += Admission of implementation
type t = implementation

let make impl = Admission (impl :> implementation)
let from handle = Handle.into handle (function Admission impl -> Some impl | _ -> None)
let require handle = from handle |> Option.to_result ~none:(Error.not_admitting ())
let check i = Handle.invoke i (fun o -> o#check)
