class type implementation = object
  method register : string -> Handle.t -> (unit, Concepts.Condition.condition) result
  method unregister : string -> (unit, Concepts.Condition.condition) result
end

type Handle.protocol += Registry of implementation

type t = implementation

let make impl = Registry impl

let from handle = Handle.into handle (function Registry impl -> Some impl | _ -> None)

let register i key value = Handle.invoke i (fun o -> o#register key value)

let unregister i key = Handle.invoke i (fun o -> o#unregister key)
