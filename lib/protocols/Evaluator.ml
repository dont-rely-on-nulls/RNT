class type implementation = object
  method invoke : Handle.t -> (Handle.t, Concepts.Condition.condition) result
end

type Handle.protocol += Evaluator of implementation
type t = implementation

let make impl = Evaluator (impl :> implementation)
let from handle = Handle.into handle (function Evaluator impl -> Some impl | _ -> None)
let require = Handle.require from
let invoke i program = Handle.invoke i (fun o -> o#invoke program)
