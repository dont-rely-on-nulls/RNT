class type implementation = object
  method update : string -> Handle.t option -> Handle.t option -> (bool, Concepts.Condition.condition) result
end

type Handle.protocol += Registry of implementation

type t = implementation

let make impl = Registry (impl :> implementation)

let from handle = Handle.into handle (function Registry impl -> Some impl | _ -> None)

let update i key reference value = Handle.invoke i (fun o -> o#update key reference value)
