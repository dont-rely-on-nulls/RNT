(** programs as source. A program in any language travels the tree as a
    handle carrying [EphemeralRelation.Stored], with its text as the code,
    so whoever holds one can run it through the evaluator of its language
    without linking that language. *)

(** a program in [language]. *)
val program : language:string -> string -> Protocols.Handle.t

(** the language and text a handle carries, if it is a program. *)
val text : Protocols.Handle.t -> (string * string) option

(** an evaluator for [language]: it runs the text of a program in that
    language, and refuses anything else. *)
val evaluator :
  language:string ->
  (string -> (Protocols.Handle.t, Concepts.Condition.condition) result) ->
  Protocols.Handle.t

(** look up the evaluator of [language] under [root]'s \evaluator and run
    [text] with it. *)
val run :
  Protocols.Handle.t ->
  language:string ->
  string ->
  (Protocols.Handle.t, Concepts.Condition.condition) result

(** register [evaluator] as \evaluator\[language] under [root]. *)
val register :
  Protocols.Handle.t ->
  language:string ->
  Protocols.Handle.t ->
  (unit, Concepts.Condition.condition) result
