(** programs as source. A program in any language travels the tree as a
    handle carrying [EphemeralRelation.Stored], with its text as the code,
    so whoever holds one can run it through the evaluator of its language
    without linking that language. *)

(** a program in [language]. *)
val program : language:string -> string -> Protocols.Handle.t

(** the language and text a handle carries, if it is a program. *)
val text : Protocols.Handle.t -> (string * string) option

(** an evaluator for [language]: it runs the text of a program in that
    language against the directory it is given, and refuses anything
    else. *)
val evaluator :
  language:string ->
  (within:Protocols.Handle.t -> string -> (Protocols.Handle.t, Concepts.Condition.condition) result) ->
  Protocols.Handle.t

(** where the evaluators are registered, from the root: \system\evaluator. *)
val evaluators : Path.t

(** run [program] through the evaluator of [language] found in
    [directory], against [within]. Usable as an
    [EphemeralRelation.binding] once [directory] and [within] are given. *)
val bind :
  Protocols.Handle.t ->
  within:Protocols.Handle.t ->
  string ->
  Protocols.Handle.t ->
  (Protocols.Handle.t, Concepts.Condition.condition) result

(** run [text] in [language] against [within], with the evaluator
    registered under [root]. *)
val run :
  Protocols.Handle.t ->
  language:string ->
  within:Protocols.Handle.t ->
  string ->
  (Protocols.Handle.t, Concepts.Condition.condition) result

(** register [evaluator] for [language] under [root]. *)
val register :
  Protocols.Handle.t ->
  language:string ->
  Protocols.Handle.t ->
  (unit, Concepts.Condition.condition) result
