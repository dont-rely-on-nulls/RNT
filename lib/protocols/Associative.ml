class type implementation = object
  method update : string -> Handle.t option -> (Handle.t, Concepts.Condition.condition) result
end

type Handle.protocol += Associative of implementation

type t = implementation

let make impl = Associative (impl :> implementation)

let from handle = Handle.into handle (function Associative impl -> Some impl | _ -> None)

let update i key value = Handle.invoke i (fun o ->
                             let open Utilities.Result in
                             let* h = o#update key value in
                             Handle.require from h)
