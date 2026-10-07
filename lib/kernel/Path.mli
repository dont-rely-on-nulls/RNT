type t

val this : t
val ( @/ ) : string -> t -> t
val of_list : string list -> t
val to_list : t -> string list
val to_string : t -> string
val lookup : Protocols.Handle.t -> t -> (Protocols.Handle.t, Concepts.Condition.condition) result

val update :
  Protocols.Handle.t ->
  t ->
  string ->
  Protocols.Handle.t option ->
  Protocols.Handle.t option ->
  (bool, Concepts.Condition.condition) result

(** [assoc handle path key value] derives [handle] with [key] under
    [path] bound to [value], or unbound when [None]. *)
val assoc :
  Protocols.Handle.t ->
  t ->
  string ->
  Protocols.Handle.t option ->
  (Protocols.Handle.t, Concepts.Condition.condition) result

(** every change of [assoc] at once: each object on the way is derived
    once, so the changes to a branch land as one successor state. *)
val assoc_all :
  Protocols.Handle.t ->
  (t * string * Protocols.Handle.t option) list ->
  (Protocols.Handle.t, Concepts.Condition.condition) result

(** the paths, relative to [a] and [b], that differ between them. Equal
    addresses are not descended, so this costs what changed. Every child
    is compared, so diff a branch's \multigroup rather than the branch,
    whose \previous differs whenever anything does. *)
val diff : Protocols.Handle.t -> Protocols.Handle.t -> (t list, Concepts.Condition.condition) result
