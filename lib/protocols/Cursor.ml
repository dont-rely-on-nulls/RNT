module Error = struct
  open Concepts.Condition

  let not_a_cursor () =
    condition "not-a-cursor" "A handle was expected to carry the cursor protocol and did not" empty
end

type batch = {tuples: Concepts.Tuple.t BatFingerTree.t; exhausted: bool}

class type implementation = object
  method fetch : int -> (batch, Concepts.Condition.condition) result
end

type Handle.protocol += Cursor of implementation
type t = implementation

let make impl = Cursor (impl :> implementation)
let from handle = Handle.into handle (function Cursor impl -> Some impl | _ -> None)
let require handle = from handle |> Option.to_result ~none:(Error.not_a_cursor ())
let fetch i limit = Handle.invoke i (fun o -> o#fetch limit)

let rec next i =
  let open Utilities.Result in
  let* batch = fetch i 1 in
  match BatFingerTree.front batch.tuples with
  | Some (_, tuple) -> Ok (Some tuple)
  | None -> if batch.exhausted then Ok None else next i

let drain i ?(limit = 256) () =
  let open Utilities.Result in
  let rec loop tuples =
    let* batch = fetch i limit in
    let tuples = BatFingerTree.append tuples batch.tuples in
    if batch.exhausted then Ok tuples else loop tuples
  in
  loop BatFingerTree.empty
