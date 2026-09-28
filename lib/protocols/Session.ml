type state = {branch: string; snapshot: Concepts.Hash.hash}

class type implementation = object
  method state : state
  method pin : state -> unit
end

type Handle.protocol += Session of implementation
type t = implementation

let make impl = Session (impl :> implementation)
let from handle = Handle.into handle (function Session impl -> Some impl | _ -> None)
let state i = Handle.invoke i (fun o -> o#state)
let pin i state = Handle.invoke i (fun o -> o#pin state)
