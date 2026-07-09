(** Compiles relational plans ([Plan.t]) into lazy tuple streams and
    runs them against a storage backend. *)

module Tuple = struct
  module AttributeMap = BatMap.String

  (* TODO: The assumption here is that every value is stringified *)
  (* TODO: The field [type'] currently is not enforced as all the
     available types of RNT *)
  type attribute = {value: string; type': string}
  (** An attribute value tagged with its type. *)

  type t = attribute AttributeMap.t
  (** A tuple: a finite map from attribute name to attribute. *)

  (** [empty] The tuple with no attributes. *)
  let empty : t = AttributeMap.empty

  (** [access name t] Looks up the attribute bound to [name] in [t].
      @param name attribute name to look up.
      @param t tuple to search.
      @return the attribute, or [None] when [name] is unbound. *)
  let access (name : string) (t : t) : attribute option = AttributeMap.find_opt name t

  (** [merge left right] Combines two tuples. An attribute present on
      only one side is kept; an attribute present on both is kept when
      the values are equal and dropped when they differ.
      @param left first tuple.
      @param right second tuple.
      @return the merged tuple. *)
  let merge (left : t) (right : t) : t =
    let merger _ (left : attribute option) (right : attribute option) : attribute option =
      match left, right with
      | Some a, Some b -> if a = b then Some a else None
      | (Some _ as a), None | None, (Some _ as a) -> a
      | None, None -> None
    in
    AttributeMap.merge merger left right

  (** [project keep t] Keeps only the attributes of [t] whose names are
      in [keep].
      @param keep set of attribute names to retain.
      @param t tuple to project.
      @return the projected tuple. *)
  let project (keep : BatSet.String.t) (t : t) : t =
    AttributeMap.filter (fun name _ -> BatSet.String.mem name keep) t

  (** [rename mapping t] Renames the attributes of [t] through
      [mapping]; names absent from [mapping] are left unchanged.
      @param mapping map from old name to new name.
      @param t tuple to rename.
      @return the renamed tuple. *)
  let rename (mapping : string BatMap.String.t) (t : t) : t =
    AttributeMap.fold
      (fun name attr acc ->
        let name = BatMap.String.find_default name name mapping in
        AttributeMap.add name attr acc )
      t AttributeMap.empty
end

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

type stream = Tuple.t BatSeq.t
(** A lazy stream of tuples. *)

(* TODO: represent a missing [Var] as something better than [""]. *)

(** [resolve args bindings] Instantiates a scan-argument template
    against [bindings], replacing each [Var] with its bound value and
    each [Const] with its literal. A [Var] with no binding resolves to
    [""].
    @param args argument template.
    @param bindings tuple supplying the variable values.
    @return the resolved arguments. *)
let resolve (args : Plan.path_arg BatFingerTree.t) (bindings : Tuple.t) : string BatFingerTree.t =
  BatFingerTree.map
    (function
     | Plan.Const value -> value
     | Plan.Var name -> (match Tuple.access name bindings with Some a -> a.value | None -> "" ))
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
      ~(offset : int) : Tuple.t BatFingerTree.t =
    ignore (relation, args, offset) ;
    failwith "NOT IMPLEMENTED: Merkle paging over Store.get"

  (** [scan txn ~relation ~args] Streams the tuples of [relation] one
      page at a time; forcing a stream node re-reads its page.
      @return the tuple stream. *)
  let scan (txn : Store.transaction) ~(relation : string) ~(args : string BatFingerTree.t) : stream =
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
  let rec compile (txn : Store.transaction) : Plan.t -> Tuple.t -> stream = function
    | Scan {relation; args} -> fun bindings -> scan txn ~relation ~args:(resolve args bindings)
    | Project {attrs; from} ->
       let from = compile txn from in
       fun bindings -> BatSeq.map (Tuple.project attrs) (from bindings)
    | Rename {attrs; from} ->
       let from = compile txn from in
       fun bindings -> BatSeq.map (Tuple.rename attrs) (from bindings)
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
         BatSet.String.for_all (fun attr -> Tuple.access attr l = Tuple.access attr r) attrs
       in
       fun bindings ->
       left bindings
       |> BatSeq.concat_map (fun l -> right l |> BatSeq.filter (matches l) |> BatSeq.map (Tuple.merge l))
    | Materialize from ->
       let cached = lazy (BatSeq.memoize (compile txn from Tuple.empty)) in
       fun _ -> Lazy.force cached

  (** [run txn plan] Executes [plan] under the empty binding.
      @return the resulting tuple stream. *)
  let run (txn : Store.transaction) (plan : Plan.t) : stream = compile txn plan Tuple.empty
end
