(** a namespace that keeps its history: each binding it accepts is a
    commit of [Protocols.Journal]. It answers [Directory] and [Registry]
    as a plain namespace does, so a subsystem that only knows those
    commits without knowing it. *)

(** a journal whose first commit, numbered 0, binds [bindings]. *)
val make : ?bindings:(string * Protocols.Handle.t) list -> unit -> Protocols.Handle.t

(** a journal whose first commit binds whatever [directory] binds now. *)
val adopt : Protocols.Handle.t -> (Protocols.Handle.t, Concepts.Condition.condition) result

(** a directory of [bindings] that, asked for a derived relation, hands
    it out read against itself. *)
val snapshot : (string * Protocols.Handle.t) list -> Protocols.Handle.t

(** bind each name to its handle, or unbind it, whatever it was bound to
    before: as one commit when [directory] is a journal, and one name at
    a time when it is a plain namespace. *)
val rebind :
  Protocols.Handle.t ->
  (string * Protocols.Handle.t option) list ->
  (unit, Concepts.Condition.condition) result
