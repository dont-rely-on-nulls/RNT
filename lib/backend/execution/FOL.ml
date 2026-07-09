(** Compiles relational plans ([Plan.t]) into lazy tuple streams and
    runs them by pulling tuples through a cursor manager
    ([Managers.Cursor.CURSOR_MANAGER]).

    A [Plan.t] holds no runtime state. [compile] turns it into a lazy
    [stream], which does. [Join] re-scans its inner side once per outer
    tuple by re-applying the compiled function to a fresh binding. Only
    [Materialize] keeps anything between runs, because it caches. *)

(** The operator tree. One constructor per operator, holding its
    description and no runtime state. *)
module Plan = struct
  (** One [args] segment. [args] feed an ephemeral relation's generator
      and are ignored for stored relations.
      [Var "x"] is an attribute name. It resolves to the outer tuple's
      value for ["x"] ([Value.value]).
      [Const v] is a literal value ([Value.value]). *)
  type path_arg = Var of string | Const of Concepts.Value.value

  type t =
    (* [path] is the relation's namespace address: fixed strings that
       [Object.find] walks. [args] are ephemeral generator inputs, not
       part of the namespace. *)
    | Scan of {path: string BatFingerTree.t; args: path_arg BatFingerTree.t}
    | Join of {left: t; right: t; attrs: BatSet.String.t}
    | Take of {limit: int; from: t}
    | Project of {attrs: BatSet.String.t; from: t}
    | Materialize of t
    | Rename of {attrs: string BatMap.String.t; from: t}
    | Union of t BatFingerTree.t
end

type stream = (Concepts.Tuple.t, Concepts.Condition.condition) result BatSeq.t
(** A lazy stream of tuples. Each node is either a tuple or a
    [condition] saying why the stream stopped there. *)

(** [singleton x] The stream with the single element [x]. *)
let singleton (x : ('a, 'e) result) : ('a, 'e) result BatSeq.t =
  fun () -> BatSeq.Cons (x, BatSeq.empty)

(*
  1. Figure out block nested loop joins with path variables
 *)

(** Condition builders for execution errors. *)
module Error = struct
  open Concepts.Condition

  (** A [Var] named [name] but no such attribute is bound in the outer
      tuple. *)
  let unbound_variable name =
    condition "unbound-variable"
      (Printf.sprintf "path variable %S is not bound in the enclosing tuple" name)
      ("variable" |=| Concepts.Value.String name)
end

(** [resolve args bindings] turns an [args] template into the value
    vector fed to a relation's generator: each [Var] becomes the value
    bound to that attribute, each [Const] stays as is.
    @param args argument template.
    @param bindings tuple supplying the variable values.
    @return the resolved argument values, or [unbound_variable] when a
    [Var] has no binding. *)
let resolve (args : Plan.path_arg BatFingerTree.t) (bindings : Concepts.Tuple.t) :
    (Concepts.Value.value BatFingerTree.t, Concepts.Condition.condition) result =
  let open Utilities.Result in
  BatFingerTree.fold_left
    (fun acc arg ->
      let* acc = acc in
      match arg with
      | Plan.Const value -> Ok (BatFingerTree.snoc acc value)
      | Plan.Var name ->
         (match Concepts.Tuple.access name bindings with
          | Some value -> Ok (BatFingerTree.snoc acc value)
          | None -> Error (Error.unbound_variable name)))
    (Ok BatFingerTree.empty)
    args

(** Compiles and runs plans by pulling tuples through a cursor manager
    ([Managers.Cursor.CURSOR_MANAGER]). Relation paths, Merkle paging,
    and the object namespace all live behind that seam. This module
    never touches storage or the object tree directly. *)
module Make (Cursors : Managers.Cursor.CURSOR_MANAGER) = struct
  (** [scan cursors ~path ~args] opens a cursor on the relation at
      [path] and streams its tuples, one per stream node. A paging
      failure comes through as an [Error] node. The cursor is closed at
      exhaustion. *)
  let scan (cursors : Cursors.t) ~(path : string BatFingerTree.t)
      ~(args : Concepts.Value.value BatFingerTree.t) : stream =
    match Cursors.open_ cursors ~path ~args with
    | Error condition -> singleton (Error condition)
    | Ok cursor ->
       let rec pull () =
         match Cursors.next cursor with
         | Error condition -> BatSeq.Cons (Error condition, BatSeq.empty)
         | Ok None -> Cursors.close cursor ; BatSeq.Nil
         | Ok (Some tuple) -> BatSeq.Cons (Ok tuple, pull)
       in
       pull

  (** [compile cursors plan] compiles [plan] into a function from a
      binding tuple to its tuple stream.
      @return the compiled stream builder. *)
  let rec compile (cursors : Cursors.t) : Plan.t -> Concepts.Tuple.t -> stream = function
    | Scan {path; args} ->
       fun bindings ->
       (match resolve args bindings with
        | Ok args -> scan cursors ~path ~args
        | Error condition -> singleton (Error condition))
    | Project {attrs; from} ->
       let from = compile cursors from in
       fun bindings -> BatSeq.map (Result.map (Concepts.Tuple.project attrs)) (from bindings)
    | Rename {attrs; from} ->
       let from = compile cursors from in
       fun bindings -> BatSeq.map (Result.map (Concepts.Tuple.rename attrs)) (from bindings)
    | Take {limit; from} ->
       let from = compile cursors from in
       fun bindings -> BatSeq.take limit (from bindings)
    | Union plans ->
       let compiled = BatFingerTree.map (compile cursors) plans in
       fun bindings ->
       BatFingerTree.fold_right (fun rest c -> BatSeq.append (c bindings) rest) BatSeq.empty compiled
    | Join {left; right; attrs} ->
       let left = compile cursors left and right = compile cursors right in
       let matches l r =
         BatSet.String.for_all (fun attr -> Concepts.Tuple.access attr l = Concepts.Tuple.access attr r) attrs
       in
       fun bindings ->
       left bindings
       |> BatSeq.concat_map
            (function
             | Error _ as error -> singleton error
             | Ok l ->
                right l
                |> BatSeq.filter (function Ok r -> matches l r | Error _ -> true)
                |> BatSeq.map (Result.map (Concepts.Tuple.merge l)))
    | Materialize from ->
       let cached = lazy (BatSeq.memoize (compile cursors from Concepts.Tuple.empty)) in
       fun _ -> Lazy.force cached

  (** [run cursors plan] Executes [plan] under the empty binding.
      @return the resulting tuple stream. *)
  let run (cursors : Cursors.t) (plan : Plan.t) : stream =
    compile cursors plan Concepts.Tuple.empty
end
