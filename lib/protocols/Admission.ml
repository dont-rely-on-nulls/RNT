type violations = (string * Concepts.Tuple.t) list

class type implementation = object
  method check : (violations, Concepts.Condition.condition) result
end

type Handle.protocol += Admission of implementation
type t = implementation

let make impl = Admission (impl :> implementation)
let from handle = Handle.into handle (function Admission impl -> Some impl | _ -> None)
let require = Handle.require from
let check i = Handle.invoke i (fun o -> o#check)
