type _ Effect.t += Yield : Concepts.Tuple.t -> unit Effect.t

type step =
  | Element of Concepts.Tuple.t * (unit, step) Effect.Deep.continuation
  | Finished of (unit, Concepts.Condition.condition) result

let start produce =
  try Finished (produce ~yield:(fun tuple -> Effect.perform (Yield tuple))) with
  | effect (Yield tuple), k -> Element (tuple, k)

let resume k = Effect.Deep.continue k ()

class producer_cursor produce on_release =
  object (self)
    inherit Lifecycle.null
    inherit Identity.of_id

    val mutable state : [`Fresh | `Live of (unit, step) Effect.Deep.continuation | `Done] = `Fresh
    method protocols : Protocols.Handle.protocol list = Protocols.[Cursor.make self]
    method private step : (Concepts.Tuple.t option, Concepts.Condition.condition) result =
      let settle = function
        | Element (tuple, k) ->
            state <- `Live k;
            Ok (Some tuple)
        | Finished r ->
            state <- `Done;
            Result.map (fun () -> None) r
      in
      match state with
      | `Done -> Ok None
      | `Fresh -> settle (start produce)
      | `Live k -> settle (resume k)

    method fetch limit =
      let open Utilities.Result in
      let rec fill taken tuples =
        if taken >= limit then Ok Protocols.Cursor.{tuples; exhausted= false}
        else
          let* stepped = self#step in
          match stepped with
          | None -> Ok Protocols.Cursor.{tuples; exhausted= true}
          | Some tuple -> fill (taken + 1) (BatFingerTree.snoc tuples tuple)
      in
      if limit <= 0 then
        Ok Protocols.Cursor.{tuples= BatFingerTree.empty; exhausted= (state = `Done)}
      else fill 0 BatFingerTree.empty

    method! release =
      (match state with
       | `Live _ -> Option.iter (fun f -> f ()) on_release
       | `Fresh | `Done -> ());
      state <- `Done
  end

let cursor_of ?on_release produce =
  new producer_cursor produce on_release |> Protocols.Handle.make
