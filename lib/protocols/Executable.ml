class type implementation = object
  method invoke :
    Handle.t list -> within:Handle.t -> (Handle.t, Concepts.Condition.condition) result
end

type Handle.protocol += Executable of implementation
type t = implementation

let make impl = Executable (impl :> implementation)
let from handle = Handle.into handle (function Executable impl -> Some impl | _ -> None)
let require = Handle.require from
let invoke i inputs ~within = Handle.invoke i (fun o -> o#invoke inputs ~within)
