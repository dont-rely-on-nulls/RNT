module Error = struct
  open Concepts.Condition

  let unknown_name name =
    condition "unknown-name"
      "A term named neither a bound variable nor a relation existing under this snapshot"
      ("name" |=| Concepts.Value.String name)
  let not_applicable () =
    condition "not-applicable"
      "A term was applied to an argument, but it denotes a relation rather than an abstraction"
      empty
  let unapplied_abstraction () =
    condition "unapplied-abstraction"
      "A program reduced to an abstraction, which names no relation to enumerate" empty
  let cancelled () =
    condition "evaluation-cancelled" "An evaluation was stopped before it produced its result" empty
end

(* A dummy untyped lambda calculus where constants are relations. We
   look for a name in the environment first and resolved through the
   context otherwise, so the relations reachable under the snapshot
   are the outer environment every program is evaluated on *)
type term =
  | Name of string
  | Abstract of string * term
  | Apply of term * term

module Program = Protocols.Program.Make (struct
  type t = term
end)

type value =
  | Relation of Protocols.Handle.t
  | Closure of string * term * environment
and environment = value BatMap.String.t

let reduce context ~acquire term =
  let open Utilities.Result in
  let rec eval environment term =
    match context.Protocols.Context.status () with
    | `Cancelled | `Exhausted -> Error (Error.cancelled ())
    | `Live ->
       match term with
       | Name name ->
          begin match BatMap.String.find_opt name environment with
           | Some value -> Ok value
           | None ->
              let* found = Runtime.Context.resolve context name in
              let* handle = Option.to_result ~none:(Error.unknown_name name) found in
              Ok (Relation (acquire handle))
          end
       | Abstract (binder, body) -> Ok (Closure (binder, body, environment))
       | Apply (operator, operand) ->
          let* operator = eval environment operator in
          match operator with
          | Relation _ -> Error (Error.not_applicable ())
          | Closure (binder, body, closed) ->
             let* argument = eval environment operand in
             eval (BatMap.String.add binder argument closed) body
  in
  eval BatMap.String.empty term

(* Every handle resolved during reduction is released once the result
   has been enumerated and we keep a closure free to carry a relation
   it did not resolve itself *)
let execute context term =
  let open Utilities.Result in
  let acquired = ref [] in
  let acquire handle =
    acquired := handle :: !acquired;
    handle
  in
  Fun.protect
    ~finally:(fun () -> List.iter Protocols.Handle.release !acquired)
    (fun () ->
      let* value = reduce context ~acquire term in
      match value with
      | Closure _ -> Error (Error.unapplied_abstraction ())
      | Relation handle ->
         let* enumerable = Protocols.Enumerable.require handle in
         Protocols.Enumerable.enumerate enumerable context)

class evaluator = object (self)
  inherit Kernel.Lifecycle.null
  inherit Kernel.Identity.of_id
  method invoke ~program context = execute context program
  method protocols : Protocols.Handle.protocol list = [Program.make self]
end

let make () = new evaluator |> Protocols.Handle.make
