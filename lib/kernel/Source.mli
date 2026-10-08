(** programs as source. A program in any language travels the tree as a
    handle carrying [EphemeralRelation.Stored], with its text as the code,
    so whoever holds one can run it through the evaluator of its language
    without linking that language.

    An evaluator is named [scope:language] and registered at
    \[scope]\evaluator\[language]; a bare [language] is the system's. *)

(** a program in [language], to run. *)
val program : language:string -> string -> Protocols.Handle.t

(** a program in [language] defining a relation of [heading], to store in
    a branch, where reading it runs it. *)
val view :
  language:string ->
  heading:Protocols.Schematics.relation_description ->
  string ->
  Protocols.Handle.t

(** the evaluator and text a handle carries, if it is a program. *)
val text : Protocols.Handle.t -> (string * string) option

(** an evaluator name split into its scope and language. *)
val reference : string -> string * string

(** an evaluator for [language]. A stored relation read from a branch is
    given to [view] with its name: what the source defines under that
    name, read [within] the branch state. Anything else is given to
    [run]. *)
val evaluator :
  language:string ->
  ?view:
    (within:Protocols.Handle.t ->
    name:string ->
    string ->
    (Protocols.Handle.t, Concepts.Condition.condition) result ) ->
  (within:Protocols.Handle.t -> string -> (Protocols.Handle.t, Concepts.Condition.condition) result) ->
  Protocols.Handle.t

(** run [program] through the evaluator named [evaluator] under [root],
    [within] the given directory. Usable as an [EphemeralRelation.binding]
    once [root] and [within] are given. *)
val bind :
  Protocols.Handle.t ->
  within:Protocols.Handle.t ->
  string ->
  Protocols.Handle.t ->
  (Protocols.Handle.t, Concepts.Condition.condition) result

(** run [text] with the evaluator named [language] under [root], [within]
    the given directory. *)
val run :
  Protocols.Handle.t ->
  language:string ->
  within:Protocols.Handle.t ->
  string ->
  (Protocols.Handle.t, Concepts.Condition.condition) result

(** register [evaluator] as \[scope]\evaluator\[language] under [root]. *)
val register :
  Protocols.Handle.t ->
  scope:string ->
  language:string ->
  Protocols.Handle.t ->
  (unit, Concepts.Condition.condition) result
