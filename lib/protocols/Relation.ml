module Error = struct
  open Concepts.Condition

  let not_a_relation () =
    condition "not-a-relation" "A handle was expected to carry the relation protocol and did not"
      empty
end

class type implementation = object
  method contains : Concepts.Tuple.t -> (bool, Concepts.Condition.condition) result
end

type Handle.protocol += Relation of implementation
type t = implementation

let make impl = Relation (impl :> implementation)
let from handle = Handle.into handle (function Relation impl -> Some impl | _ -> None)
let require handle = from handle |> Option.to_result ~none:(Error.not_a_relation ())
let contains i tuple = Handle.invoke i (fun o -> o#contains tuple)

let read relation =
  let open Utilities.Result in
  let* schematics = Handle.require Schematics.from relation in
  let* description = Schematics.describe schematics in
  let* heading =
    match description with
    | Schematics.Relation heading -> Ok heading
    | _ -> Error (Error.not_a_relation ())
  in
  let* enumerable = Enumerable.require relation in
  let* cursor = Enumerable.enumerate enumerable in
  Fun.protect
    ~finally:(fun () -> Handle.release cursor)
    (fun () ->
      let* scan = Cursor.require cursor in
      let* tuples = Cursor.drain scan () in
      Ok (heading, BatFingerTree.to_list tuples) )
