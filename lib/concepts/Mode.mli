type attributes = BatSet.String.t

(** given [bound], every matching tuple can be produced, and there are
    at most [yields]. *)
type mode = {bound: attributes; yields: Cardinality.t}

type t = mode list

val mode : string list -> Cardinality.t -> mode
val generation : t -> attributes -> Cardinality.t option
val exhaustible : t -> attributes -> bool

(** the modes still usable when only [attributes] can be bound. *)
val project : attributes -> t -> t
