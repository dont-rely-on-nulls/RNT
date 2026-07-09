(** Compiles relational plans ([Plan.t]) into lazy tuple streams and
    runs them against a storage backend. *)

(** The relational operator tree. Each constructor is one operator and
    carries only its description. *)
module Plan = struct
  (** One segment of a [Scan]'s relation-path arguments. [Var] is
      resolved from the enclosing bindings at execution time; [Const]
      is a fixed literal. *)
  type path_arg = Var of string | Const of string

  type t =
    | Scan of {relation: string; args: path_arg BatFingerTree.t}
    | Join of {left: t; right: t; attrs: BatSet.String.t}
    | Take of {limit: int; from: t}
    | Project of {attrs: BatSet.String.t; from: t}
    | Materialize of t
    | Rename of {attrs: string BatMap.String.t; from: t}
    | Union of t BatFingerTree.t
end

type stream = (Concepts.Tuple.t, Concepts.Condition.condition) result BatSeq.t
(** A lazy stream of tuples. Each node is either a resolved tuple or a
    [condition] describing why the stream could not be produced past
    that point. *)

(** [singleton x] The stream with the single element [x]. *)
let singleton (x : ('a, 'e) result) : ('a, 'e) result BatSeq.t =
  fun () -> BatSeq.Cons (x, BatSeq.empty)

(*
  1. Figure out block nested loop joins with path variables
  2. Revise the string paths for relations under the Ob tree
 *)

(** Condition builders for execution errors. *)
module Error = struct
  open Concepts.Condition

  (** [unbound_variable name] A [Var] segment referenced [name], but no
      such attribute was bound in the enclosing tuple. *)
  let unbound_variable name =
    condition "unbound-variable"
      (Printf.sprintf "path variable %S is not bound in the enclosing tuple" name)
      ("variable" |=| Concepts.Value.String name)
end

(** [resolve args bindings] Instantiates a scan-argument template
    against [bindings], replacing each [Var] with the string form of
    its bound value and each [Const] with its literal.
    @param args argument template.
    @param bindings tuple supplying the variable values.
    @return the resolved arguments, or [unbound_variable] when a [Var]
    has no binding. *)
let resolve (args : Plan.path_arg BatFingerTree.t) (bindings : Concepts.Tuple.t) :
    (string BatFingerTree.t, Concepts.Condition.condition) result =
  let open Utilities.Result in
  BatFingerTree.fold_left
    (fun acc arg ->
      let* acc = acc in
      match arg with
      | Plan.Const value -> Ok (BatFingerTree.snoc acc value)
      | Plan.Var name ->
         (match Concepts.Tuple.access name bindings with
          | Some value -> Ok (BatFingerTree.snoc acc (Concepts.Value.to_string value))
          | None -> Error (Error.unbound_variable name)))
    (Ok BatFingerTree.empty)
    args

(** Compiles and runs plans against a content-addressed storage backend
    ([Abstract.Storage.STORAGE]). Scan leaves page tuples out of a
    relation through the store within a single transaction. *)
module Make (Store : Abstract.Storage.STORAGE) = struct
  (** [page txn ~relation ~args ~offset] Reads one page of [relation]'s
      tuples starting at [offset]: resolves [relation] to a Merkle root,
      fetches a page of tuple hashes, reads each blob through
      [Store.get], and deserializes them into tuples. [args] supplies
      the bound values for parameterized relations and is ignored for
      stored ones.
      @return the page of tuples; an empty page marks exhaustion.

      Not implemented: relation-to-root resolution, Merkle paging, and
      the blob-to-tuple codec do not exist yet. *)
  let page (_txn : Store.transaction) ~(relation : string) ~(args : string BatFingerTree.t)
      ~(offset : int) : Concepts.Tuple.t BatFingerTree.t =
    ignore (relation, args, offset) ;
    failwith "NOT IMPLEMENTED: Merkle paging over Store.get"

  (** [scan txn ~relation ~args] Streams the tuples of [relation] one
      page at a time; forcing a stream node re-reads its page.
      @return the tuple stream. *)
  let scan (txn : Store.transaction) ~(relation : string) ~(args : string BatFingerTree.t) :
      Concepts.Tuple.t BatSeq.t =
    let rec from offset () =
      let p = page txn ~relation ~args ~offset in
      if BatFingerTree.is_empty p then BatSeq.Nil
      else
        let rest = from (offset + BatFingerTree.size p) in
        (BatFingerTree.fold_right (fun rest tuple () -> BatSeq.Cons (tuple, rest)) rest p) ()
    in
    from 0

  (** [compile txn plan] Compiles [plan] into a function from a binding
      tuple to a tuple stream.
      @return the compiled stream builder. *)
  let rec compile (txn : Store.transaction) : Plan.t -> Concepts.Tuple.t -> stream = function
    | Scan {relation; args} ->
       fun bindings ->
       (match resolve args bindings with
        | Ok args -> BatSeq.map Result.ok (scan txn ~relation ~args)
        | Error condition -> singleton (Error condition))
    | Project {attrs; from} ->
       let from = compile txn from in
       fun bindings -> BatSeq.map (Result.map (Concepts.Tuple.project attrs)) (from bindings)
    | Rename {attrs; from} ->
       let from = compile txn from in
       fun bindings -> BatSeq.map (Result.map (Concepts.Tuple.rename attrs)) (from bindings)
    | Take {limit; from} ->
       let from = compile txn from in
       fun bindings -> BatSeq.take limit (from bindings)
    | Union plans ->
       let compiled = BatFingerTree.map (compile txn) plans in
       fun bindings ->
       BatFingerTree.fold_right (fun rest c -> BatSeq.append (c bindings) rest) BatSeq.empty compiled
    | Join {left; right; attrs} ->
       let left = compile txn left and right = compile txn right in
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
       let cached = lazy (BatSeq.memoize (compile txn from Concepts.Tuple.empty)) in
       fun _ -> Lazy.force cached

  (** [run txn plan] Executes [plan] under the empty binding.
      @return the resulting tuple stream. *)
  let run (txn : Store.transaction) (plan : Plan.t) : stream = compile txn plan Concepts.Tuple.empty
end
