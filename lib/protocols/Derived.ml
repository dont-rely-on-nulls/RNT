class type implementation = object
  method within : Handle.t -> (Handle.t, Concepts.Condition.condition) result
end

type Handle.protocol += Derived of implementation
type t = implementation

let make impl = Derived (impl :> implementation)
let from handle = Handle.into handle (function Derived impl -> Some impl | _ -> None)
let within i directory = Handle.invoke i (fun o -> o#within directory)
