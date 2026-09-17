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

type program = Program of term * Protocols.Directory.t Protocols.Handle.interface

module Program = Protocols.Program.Make (struct
  type t = program
end)

type value =
  | Relation of Protocols.Handle.t
  | Closure of string * term * environment
and environment = value BatMap.String.t

(* let reduce context term = *)
(*   let open Utilities.Result in *)
(*   let rec eval environment term = *)
(*     match context.Protocols.Context.status () with *)
(*     | `Cancelled | `Exhausted -> Error (Error.cancelled ()) *)
(*     | `Live -> *)
(*        match term with *)
(*        | Name name -> *)
(*           begin match BatMap.String.find_opt name environment with *)
(*            | Some value -> Ok value *)
(*            | None -> *)
(*               let* found = Runtime.Context.resolve context name in *)
(*               let* handle = Option.to_result ~none:(Error.unknown_name name) found in *)
(*               Ok (Relation handle) *)
(*           end *)
(*        | Abstract (binder, body) -> Ok (Closure (binder, body, environment)) *)
(*        | Apply (operator, operand) -> *)
(*           let* operator = eval environment operator in *)
(*           match operator with *)
(*           | Relation _ -> Error (Error.not_applicable ()) *)
(*           | Closure (binder, body, closed) -> *)
(*              let* argument = eval environment operand in *)
(*              eval (BatMap.String.add binder argument closed) body *)
(*   in *)
(*   eval BatMap.String.empty term *)

let reduce (Program (term, dir)) =
  let open Utilities.Result in
  let open Protocols in
  let rec eval env term =
    match term with
    | Name name ->
       begin
         match BatMap.String.find_opt name env with
         | Some value -> Ok value
         | None ->
            let* handle = Directory.find dir name |> fmap (Option.to_result ~none:(Error.unknown_name name)) in
            Ok (Relation handle)
       end
    | Abstract (binder, body) -> Ok (Closure (binder, body, env))
    | Apply (operator, operand) ->
       let* operator = eval env operation in
       match operator with
       | Relation _ -> Error (Error.not_applicable ())
       | _ -> failwith "TODO"
  in
  eval BatMap.String.empty term

let execute term =
  let open Utilities.Result in
  let* value = reduce context term in
  match value with
  | Closure _ -> Error (Error.unapplied_abstraction ())
  | Relation handle ->
     let* enumerable = Protocols.Enumerable.require handle in
     Protocols.Enumerable.enumerate enumerable

class evaluator = object (self)
  inherit Kernel.Lifecycle.null
  inherit Kernel.Identity.of_id
  method invoke program = execute program
  method protocols : Protocols.Handle.protocol list = [Program.make self]
end

let make () = new evaluator |> Protocols.Handle.make
