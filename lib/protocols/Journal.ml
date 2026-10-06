type change = {name: string; expected: Handle.t option; replacement: Handle.t option}
type commit = {number: int; snapshot: Handle.t; changed: string list}
type proposal = {previous: commit; proposed: commit}
type guard = proposal -> (unit, Concepts.Condition.condition) result
type observer = commit -> unit

class type implementation = object
  method commit : change list -> (commit option, Concepts.Condition.condition) result
  method head : commit
  method history : commit list
  method guard : string -> guard option -> unit
  method observe : string -> observer option -> unit
end

type Handle.protocol += Journal of implementation
type t = implementation

let make impl = Journal (impl :> implementation)
let from handle = Handle.into handle (function Journal impl -> Some impl | _ -> None)
let require = Handle.require from
let commit i changes = Handle.invoke i (fun o -> o#commit changes)
let head i = Handle.invoke i (fun o -> o#head)
let history i = Handle.invoke i (fun o -> o#history)
let guard i name g = Handle.invoke i (fun o -> o#guard name g)
let observe i name f = Handle.invoke i (fun o -> o#observe name f)
