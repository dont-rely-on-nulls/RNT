module Plan = struct
  type path_arg = Var of string | Const of Concepts.Value.value

  type t =
    | Scan of {path: Concepts.Path.t; args: path_arg BatFingerTree.t}
    | Natural of {left: t; right: t}
    | Take of {limit: int; from: t}
    | Project of {attrs: BatSet.String.t; from: t}
    | Materialize of t
    | Rename of {attrs: string BatMap.String.t; from: t}
    | Union of t BatFingerTree.t
end

type control =
  | Continue
  | Stop

module Error = struct
  open Concepts.Condition

  let unbound_variable name =
    condition "unbound-variable"
      (Printf.sprintf "path variable %S is not bound in the enclosing tuple" name)
      ("variable" |=| Concepts.Value.String name)
end

let resolve (args : Plan.path_arg BatFingerTree.t) (bindings : Concepts.Tuple.t) :
    (Concepts.Value.value BatFingerTree.t, Concepts.Condition.condition) result =
  let open Utilities.Result in
  BatFingerTree.fold_left
    (fun acc arg ->
      let* acc = acc in
      match arg with
      | Plan.Const value -> Ok (BatFingerTree.snoc acc value)
      | Plan.Var name -> (
        match Concepts.Tuple.access name bindings with
        | Some value -> Ok (BatFingerTree.snoc acc value)
        | None -> Error (Error.unbound_variable name) ) )
    (Ok BatFingerTree.empty) args

type yield = Concepts.Tuple.t -> (control, Concepts.Condition.condition) result

type pusher =
  bindings:Concepts.Tuple.t -> yield:yield -> (control, Concepts.Condition.condition) result

module Make (Handler : Managers.Handle.HANDLER) = struct
  module Algebra = struct
    let rec drain cursor ~yield =
      match Handler.next cursor with
      | Error condition -> Error condition
      | Ok None -> Ok Continue
      | Ok (Some tuple) -> (
        match yield tuple with Ok Continue -> drain cursor ~yield | other -> other )

    let rec replay rows ~yield =
      match rows with
      | [] -> Ok Continue
      | tuple :: rows -> (
        match yield tuple with Ok Continue -> replay rows ~yield | other -> other )

    let scan handler cap ~path ~args : pusher =
      fun ~bindings ~yield ->
        match resolve args bindings with
        | Error condition -> Error condition
        | Ok args -> (
          match Handler.open_ handler cap ~path ~claim:Managers.Permission.Read with
          | Error condition -> Error condition
          | Ok handle -> (
            match Handler.with_cursor handle ~args (fun cursor -> drain cursor ~yield) with
            | Error condition -> Error condition
            | Ok result -> result ) )

    let project attrs (from : pusher) : pusher =
      fun ~bindings ~yield ->
        from ~bindings ~yield:(fun tuple -> yield (Concepts.Tuple.project attrs tuple))

    let rename attrs (from : pusher) : pusher =
      fun ~bindings ~yield ->
        from ~bindings ~yield:(fun tuple -> yield (Concepts.Tuple.rename attrs tuple))

    let take limit (from : pusher) : pusher =
      fun ~bindings ~yield ->
        let remaining = ref limit in
        let stopped = ref false in
        let capped tuple =
          if !remaining <= 0 then Ok Stop
          else begin
            decr remaining;
            match yield tuple with
            | Ok Stop ->
                stopped := true;
                Ok Stop
            | Ok Continue -> if !remaining <= 0 then Ok Stop else Ok Continue
            | Error condition -> Error condition
          end
        in
        ( match from ~bindings ~yield:capped with
        | Error condition -> Error condition
        | Ok _ -> if !stopped then Ok Stop else Ok Continue )

    let union (compiled : pusher BatFingerTree.t) : pusher =
      fun ~bindings ~yield ->
        BatFingerTree.fold_left
          (fun acc from -> match acc with Ok Continue -> from ~bindings ~yield | other -> other)
          (Ok Continue) compiled

    let natural (left : pusher) (right : pusher) : pusher =
      let matches l r =
        BatMap.String.for_all
          (fun name value ->
            match Concepts.Tuple.access name r with Some value' -> value = value' | None -> true )
          l
      in
      fun ~bindings ~yield ->
        left ~bindings ~yield:(fun l ->
            right ~bindings:l ~yield:(fun r ->
                if matches l r then yield (Concepts.Tuple.merge l r) else Ok Continue ) )

    let materialize (from : pusher) : pusher =
      let cache = ref None in
      fun ~bindings:_ ~yield ->
        match !cache with
        | Some rows -> replay rows ~yield
        | None -> (
            let buffer = ref [] in
            match
              from ~bindings:Concepts.Tuple.empty ~yield:(fun tuple ->
                  buffer := tuple :: !buffer;
                  Ok Continue )
            with
            | Error condition -> Error condition
            | Ok _ ->
                let rows = List.rev !buffer in
                cache := Some rows;
                replay rows ~yield )
  end

  let rec compile handler cap : Plan.t -> pusher = function
    | Scan {path; args} -> Algebra.scan handler cap ~path ~args
    | Project {attrs; from} -> Algebra.project attrs (compile handler cap from)
    | Rename {attrs; from} -> Algebra.rename attrs (compile handler cap from)
    | Take {limit; from} -> Algebra.take limit (compile handler cap from)
    | Union plans -> Algebra.union (BatFingerTree.map (compile handler cap) plans)
    | Natural {left; right} -> Algebra.natural (compile handler cap left) (compile handler cap right)
    | Materialize from -> Algebra.materialize (compile handler cap from)

  let fold handler cap plan ~init ~f =
    let acc = ref init in
    let yield tuple =
      acc := f !acc tuple;
      Ok Continue
    in
    match compile handler cap plan ~bindings:Concepts.Tuple.empty ~yield with
    | Ok _ -> Ok !acc
    | Error condition -> Error condition

  let to_list handler cap plan =
    fold handler cap plan ~init:[] ~f:(fun acc tuple -> tuple :: acc) |> Result.map List.rev
end
