(** a root over a database of its own in a temporary directory, removed
    when the program exits: for tests, and for trying things out. Its
    system evaluators are [evaluators], FOL unless told otherwise. *)
val root :
  ?evaluators:(string * Protocols.Handle.t) list ->
  unit ->
  (Protocols.Handle.t, Concepts.Condition.condition) result
