module AttributeMap = BatMap.String

type t = Value.value AttributeMap.t
(** A tuple: a finite map from attribute name to attribute. *)

(** [empty] The tuple with no attributes. *)
let empty : t = AttributeMap.empty

(** [access name t] Looks up the attribute bound to [name] in [t].
    @param name attribute name to look up.
    @param t tuple to search.
    @return the attribute, or [None] when [name] is unbound. *)
let access (name : string) (t : t) : Value.value option = AttributeMap.find_opt name t

(** [merge left right] Unions two tuples. Shared attributes take the
    [left] value; one-sided attributes are kept. Precondition: shared
    attributes agree (the natural-join matcher guarantees this), so the
    [left] bias is never observable.
    @param left first tuple.
    @param right second tuple.
    @return the merged tuple. *)
let merge (left : t) (right : t) : t =
  let merger _ (left : Value.value option) (right : Value.value option) : Value.value option =
    match left, right with
    | (Some _ as v), _ | None, (Some _ as v) -> v
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
