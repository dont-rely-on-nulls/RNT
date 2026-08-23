class type implementation = object
  method list : (string BatFingerTree.t, Concepts.Condition.condition) result
  method find : string -> (Handle.t option, Concepts.Condition.condition) result
end

type Handle.protocol += Directory of implementation

type t = implementation

let make impl = Directory (impl :> implementation)

let from handle = Handle.into handle (function Directory impl -> Some impl | _ -> None)

let list i = Handle.invoke i (fun o -> o#list)

let find i name = Handle.invoke i (fun o -> o#find name)
