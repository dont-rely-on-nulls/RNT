(** a directory that keeps its history. Every change to its bindings is
    a commit: one or more names bound again together, numbered, with a
    snapshot of every binding as it stood afterwards. Guards are shown a
    commit before it lands and may refuse it; observers are told of it
    after. *)
type t

(** bind [name] to [replacement], or unbind it when [None], provided it
    is still bound to [expected]. *)
type change = {name: string; expected: Handle.t option; replacement: Handle.t option}

(** [snapshot] is a directory of the bindings as of the commit. *)
type commit = {number: int; snapshot: Handle.t; changed: string list}

(** what a guard is shown: the commit the proposal would follow and the
    commit it would be. *)
type proposal = {previous: commit; proposed: commit}

type guard = proposal -> (unit, Concepts.Condition.condition) result
type observer = commit -> unit

class type implementation = object
  (** [Ok None] when a name was no longer bound to what was expected;
      [Error] when a guard refused. Either way nothing changes. *)
  method commit : change list -> (commit option, Concepts.Condition.condition) result

  method head : commit

  (** every commit, the oldest first. *)
  method history : commit list

  (** install, replace or remove the guard or observer of that name. *)
  method guard : string -> guard option -> unit

  method observe : string -> observer option -> unit
end

val make : #implementation -> Handle.protocol
val from : Handle.t -> t Handle.interface option
val require : Handle.t -> (t Handle.interface, Concepts.Condition.condition) result

val commit :
  t Handle.interface -> change list -> (commit option, Concepts.Condition.condition) result

val head : t Handle.interface -> commit
val history : t Handle.interface -> commit list
val guard : t Handle.interface -> string -> guard option -> unit
val observe : t Handle.interface -> string -> observer option -> unit
