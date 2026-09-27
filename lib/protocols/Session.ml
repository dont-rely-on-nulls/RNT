module Error = struct
  open Concepts.Condition

  let not_a_session () =
    condition "not-a-session" "A handle was expected to carry the session protocol and did not"
      empty
end

type state = {branch: string; snapshot: Concepts.Hash.hash}

class type implementation = object
  method state : state
  method pin : state -> unit
end

type Handle.protocol += Session of implementation
type t = implementation

let make impl = Session (impl :> implementation)
let from handle = Handle.into handle (function Session impl -> Some impl | _ -> None)
let require handle = from handle |> Option.to_result ~none:(Error.not_a_session ())
let state i = Handle.invoke i (fun o -> o#state)
let pin i state = Handle.invoke i (fun o -> o#pin state)
