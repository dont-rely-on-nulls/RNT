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

type stream = (Concepts.Tuple.t, Concepts.Condition.condition) result BatSeq.t

let singleton (x : ('a, 'e) result) : ('a, 'e) result BatSeq.t =
 fun () -> BatSeq.Cons (x, BatSeq.empty)

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
      let* value =
        match arg with
        | Plan.Const value -> Ok value
        | Plan.Var name ->
            Option.to_result ~none:(Error.unbound_variable name)
              (Concepts.Tuple.access name bindings)
      in
      Ok (BatFingerTree.snoc acc value) )
    (Ok BatFingerTree.empty) args

module Make (Handler : Managers.Handle.HANDLER) = struct
  let scan handler ~path ~args : stream =
    let opened =
      let open Utilities.Result in
      let* handle = Handler.open_ handler ~path in
      Handler.open_cursor handle ~args
    in
    match opened with
    | Error condition -> singleton (Error condition)
    | Ok cursor ->
        let rec pull () =
          match Handler.next cursor with
          | Error condition -> BatSeq.Cons (Error condition, BatSeq.empty)
          | Ok None -> BatSeq.Nil
          | Ok (Some tuple) -> BatSeq.Cons (Ok tuple, pull)
        in
        pull

  let rec compile handler : Plan.t -> Concepts.Tuple.t -> stream = function
    | Scan {path; args} -> (
        fun bindings ->
          match resolve args bindings with
          | Ok args -> scan handler ~path ~args
          | Error condition -> singleton (Error condition) )
    | Project {attrs; from} ->
        let from = compile handler from in
        fun bindings -> BatSeq.map (Result.map (Concepts.Tuple.project attrs)) (from bindings)
    | Rename {attrs; from} ->
        let from = compile handler from in
        fun bindings -> BatSeq.map (Result.map (Concepts.Tuple.rename attrs)) (from bindings)
    | Take {limit; from} ->
        let from = compile handler from in
        fun bindings -> BatSeq.take limit (from bindings)
    | Union plans ->
        let compiled = BatFingerTree.map (compile handler) plans in
        fun bindings ->
          BatFingerTree.fold_right
            (fun rest c -> BatSeq.append (c bindings) rest)
            BatSeq.empty compiled
    | Natural {left; right} ->
        let left = compile handler left and right = compile handler right in
        let matches l r =
          BatMap.String.for_all
            (fun name value ->
              match Concepts.Tuple.access name r with Some value' -> value = value' | None -> true )
            l
        in
        fun bindings ->
          left bindings
          |> BatSeq.concat_map (function
            | Error _ as error -> singleton error
            | Ok l ->
                right l
                |> BatSeq.filter (function Ok r -> matches l r | Error _ -> true)
                |> BatSeq.map (Result.map (Concepts.Tuple.merge l)) )
    | Materialize from ->
        let cached = lazy (BatSeq.memoize (compile handler from Concepts.Tuple.empty)) in
        fun _ -> Lazy.force cached

  (* TODO: This should produce ephemeral relations with support of the sublanguage to manage it. *)
  let run handler plan : stream = compile handler plan Concepts.Tuple.empty
end
