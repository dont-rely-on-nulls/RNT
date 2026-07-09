(** A plan is pure data ([Plan.t]) and execution state is never
    reified: a compiled plan is a [Seq.t], whose forcing is the
    Volcano eruption [Next]

    The only effects sit at scan leaves, and those are idempotent page
    reads against a pinned [Multigroup] snapshot. A stream node may be
    forced twice and observe the same tuples. If a truly destructive
    source ever appears, wrap its stream in [Seq.once]. *)

module Tuple = struct
  module AttributeMap = BatMap.String

  (* TODO: The assumption here is that every value is stringified *)
  (* TODO: The field [type'] currently is not enforced as all the
     available types of RNT *)
  type attribute = {value: string; type': string}
  type t = attribute AttributeMap.t

  let empty : t = AttributeMap.empty
  let access (name : string) (t : t) : attribute option = AttributeMap.find_opt name t

  let merge (left : t) (right : t) : t =
    let merger _ (left : attribute option) (right : attribute option) : attribute option =
      match left, right with
      | Some a, Some b -> if a = b then Some a else None (* conflicting binding gets droped out *)
      | (Some _ as a), None | None, (Some _ as a) -> a
      | None, None -> None
    in
    AttributeMap.merge merger left right

  let project (keep : BatSet.String.t) (t : t) : t =
    AttributeMap.filter (fun name _ -> BatSet.String.mem name keep) t

  let rename (mapping : string BatMap.String.t) (t : t) : t =
    AttributeMap.fold
      (fun name attr acc ->
        let name = BatMap.String.find_default name name mapping in
        AttributeMap.add name attr acc )
      t AttributeMap.empty
end

(** Stub of the cursor layer (CursorManager + Merkle paging). [page]
    yields the tuples of [relation] starting at [offset]; an empty
    result marks exhaustion. [args] carries the bound values for
    parameterized (ephemeral) relations and is ignored for stored
    ones. *)
module Source = struct
  type t =
    {page: relation:string -> args:string BatFingerTree.t -> offset:int -> Tuple.t BatFingerTree.t}

  let unimplemented : t = {page= (fun ~relation:_ ~args:_ ~offset:_ -> failwith "NOT IMPLEMENTED")}
end

(** The stateless operator tree representing one constructor per
    relational operator, carrying only its description without any
    associated cursors, counters and buffers. *)
module Plan = struct
  (** One segment of a parameterized relation path in a SCAN. [Var]
      segments are resolved from the enclosing JOIN's outer tuple at
      execution time; [Const] segments are ground literals fixed at
      the plan construction. *)
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

(** Compiles a [Plan.t] into a demand driven tuple stream. *)
module FOL = struct
  type stream = Tuple.t BatSeq.t

  (** Resolves a scan arguments template against the enclosing
      bindings. *)
  (* TODO: A [Var] missing from the bindings resolves to [""] to
     mirror the C++ engine. This is a poor representation in the type
     system. *)
  let resolve (args : Plan.path_arg BatFingerTree.t) (bindings : Tuple.t) : string BatFingerTree.t =
    BatFingerTree.map
      (function
        | Plan.Const value -> value
        | Plan.Var name -> (match Tuple.access name bindings with Some a -> a.value | None -> "" ))
      args

  (** Pages through [relation] one fetch at a time. The offset lives
      in the closure of each stream node, so re-forcing any node
      re-reads the same page. This is the functional equivalent of the
      cursor's [fetch_offset]. Only the current page should be
      live. *)
  let scan (src : Source.t) ~(relation : string) ~(args : string BatFingerTree.t) : stream =
    let rec from offset () =
      let page = src.page ~relation ~args ~offset in
      if BatFingerTree.is_empty page then BatSeq.Nil
      else
        let rest = from (offset + BatFingerTree.size page) in
        (BatFingerTree.fold_right (fun rest tuple () -> BatSeq.Cons (tuple, rest)) rest page) ()
    in
    from 0
end
