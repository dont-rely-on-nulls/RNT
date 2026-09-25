type attribute = string
type attributes = BatSet.String.t

(** what asking a relation under a given set of bound attributes
    affords. The answer is to whether anything satisfies the binding,
    or the bindings of the attributes left free together with the
    class of what is produced. *)
type affordance = Decides | Generates of Cardinality.t

type mode = {bound: attributes; affords: affordance}
type t

val attributes_of_list : attribute list -> attributes
val attributes_of_map : 'a BatMap.String.t -> attributes
val decides_when : attribute list -> mode
val generates_when : attribute list -> Cardinality.t -> mode
val enumerable : Cardinality.t -> mode
val of_list : mode list -> t

(** the tightest class declared for generating under [bound]. A mode
    declared for fewer bound attributes applies to more, since the
    attributes left free are then fewer and no more numerous. *)
val generation : t -> attributes -> Cardinality.t option

val exhaustible : t -> attributes -> bool

(** declared outright, or implied by a generation that can be exhausted. *)
val decision : t -> attributes -> bool
