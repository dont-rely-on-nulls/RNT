type kind = ..

class type implementation = object
  method parse : string -> (kind, Concepts.Condition.condition) result

  method eval :
    kind -> Handle.t list -> within:Handle.t -> (Handle.t, Concepts.Condition.condition) result
end

type Handle.protocol += Evaluator of implementation
type t = implementation

let make impl = Evaluator (impl :> implementation)
let from handle = Handle.into handle (function Evaluator impl -> Some impl | _ -> None)
let require = Handle.require from
let parse i source = Handle.invoke i (fun o -> o#parse source)
let eval i kind inputs ~within = Handle.invoke i (fun o -> o#eval kind inputs ~within)
