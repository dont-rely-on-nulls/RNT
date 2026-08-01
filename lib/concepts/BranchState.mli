type t
type address = Hash.hash

include Object.S with type t := t

(** Durable state of one branch head.

    [current] is the branch-visible catalog root, not the runtime namespace
    rooted at [/system]. Runtime scaffolding is rebuilt during initialization.
    [history] is the ordered commit-stream tree root. [tip] is absent until the
    first real commit, so initialization does not create a synthetic commit just
    to make the branch non-empty. *)
val make : current:address -> history:address -> tip:address option -> t

val current : t -> address
val history : t -> address
val tip : t -> address option
