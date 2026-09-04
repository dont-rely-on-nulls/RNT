(* TODO: Move cursor ownership to a standalone CursorManager and have
   [Relation.enumerate] return a handle exposing a Cursor protocol. The
   cursor must remain pinned to an immutable relation root and retain no
   storage transaction. *)
module Cursor = struct
  type state = Open | Closed | Failed of Concepts.Condition.condition

  type t = {
    next_ : unit -> (Concepts.Blob.t option, Concepts.Condition.condition) result;
    close_ : unit -> unit;
    mutable state : state
  }

  let make ~next ~close = {next_= next; close_= close; state= Open}

  let close cursor =
    match cursor.state with
    | Closed -> ()
    | Failed _ -> cursor.state <- Closed
    | Open ->
        cursor.state <- Closed;
        cursor.close_ ()

  let next cursor =
    match cursor.state with
    | Closed -> Ok None
    | Failed condition -> Error condition
    | Open ->
        match cursor.next_ () with
        | Ok None ->
            cursor.state <- Closed;
            cursor.close_ ();
            Ok None
        | Error condition ->
            cursor.state <- Failed condition;
            cursor.close_ ();
            Error condition
        | Ok (Some _ as tuple) -> Ok tuple
end

class type implementation = object
  method heading : (Concepts.Hash.hash, Concepts.Condition.condition) result
  method predicate : (Concepts.Hash.hash option, Concepts.Condition.condition) result
  method local_constraints : (Concepts.Hash.hash option, Concepts.Condition.condition) result
  method tuples : (Concepts.Hash.hash, Concepts.Condition.condition) result
  method contains : Concepts.Blob.t -> (bool, Concepts.Condition.condition) result
  method enumerate : Cursor.t
end

type Handle.protocol += Relation of implementation
type t = implementation

let make impl = Relation (impl :> implementation)
let from handle = Handle.into handle (function Relation impl -> Some impl | _ -> None)
let heading i = Handle.invoke i (fun o -> o#heading)
let predicate i = Handle.invoke i (fun o -> o#predicate)
let local_constraints i = Handle.invoke i (fun o -> o#local_constraints)
let tuples i = Handle.invoke i (fun o -> o#tuples)
let contains i tuple = Handle.invoke i (fun o -> o#contains tuple)
let enumerate i = Handle.invoke i (fun o -> o#enumerate)
