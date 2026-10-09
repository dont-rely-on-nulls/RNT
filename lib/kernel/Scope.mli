(** A branch state read from a home: a [Directory] of relations where
    [R] names the home schema's, [s:R] a schema's of the home multigroup,
    and [m:s:R] anyone's in the branch state. It lists the home schema. *)

type home = {multigroup: string; schema: string}

class type implementation = object
  (** the branch state read *)
  method branch : Protocols.Handle.t

  method home : home

  (** the same home in the state before, if there is one *)
  method previous : (Protocols.Handle.t option, Concepts.Condition.condition) result

  (** every relation of the branch state, as [m:s:R] *)
  method catalog : (string list, Concepts.Condition.condition) result
end

type Protocols.Handle.protocol += Scope of implementation

val make : Protocols.Handle.t -> home -> Protocols.Handle.t

(** [home] in the head of \system\branch\[branch]. *)
val of_root :
  Protocols.Handle.t ->
  branch:string ->
  home ->
  (Protocols.Handle.t, Concepts.Condition.condition) result

val require :
  Protocols.Handle.t ->
  (implementation Protocols.Handle.interface, Concepts.Condition.condition) result

val branch : implementation Protocols.Handle.interface -> Protocols.Handle.t
val home : implementation Protocols.Handle.interface -> home

val previous :
  implementation Protocols.Handle.interface ->
  (Protocols.Handle.t option, Concepts.Condition.condition) result

val catalog :
  implementation Protocols.Handle.interface -> (string list, Concepts.Condition.condition) result

(** \multigroup\[m]\schema\[s]\relation, from a branch state. *)
val relations : home -> Path.t

(** \multigroup\[m]\schema\[s]\relation\[relation], from a branch state. *)
val path : home -> string -> Path.t

(** where [text] names a relation, read from [home], from a branch state. *)
val locate : home -> string -> Path.t option

(** the attribute [text] names of the relation named [relation], both read
    from [home]: bare, or qualified with a name of that relation. *)
val attribute : home -> string -> string -> string option

(** bind each named relation to its value, or unbind it on [None], in the
    head of \system\branch\[branch], as one successor state. A multigroup
    or schema not there yet is made, and a value with no address is
    stored as a schema stores it: a program as itself, a relation as its
    tuples. [denials] are named [d], in
    \denial of the home multigroup, or [m:d], in that of [m]. If the head moved meanwhile, or a multigroup does not
    admit the state, nothing changes, and it fails. *)
val publish :
  ?denials:(string * Protocols.Handle.t option) list ->
  Protocols.Handle.t ->
  branch:string ->
  home:home ->
  (string * Protocols.Handle.t option) list ->
  (unit, Concepts.Condition.condition) result
