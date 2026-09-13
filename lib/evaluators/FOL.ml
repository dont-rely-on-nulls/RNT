module Error = struct
  open Concepts.Condition

  let unknown_relation name =
    condition "unknown-relation" "A plan named a relation that does not exist under this snapshot"
      ("name" |=| Concepts.Value.String name)

  let cancelled () =
    condition "evaluation-cancelled" "An evaluation was stopped before it produced its result" empty
end

type plan = Base of string

module Program = Protocols.Program.Make (struct
  type t = plan
end)

let execute context = function
  | Base name ->
     let open Utilities.Result in
     match context.Protocols.Context.status () with
     | `Cancelled | `Exhausted -> Error (Error.cancelled ())
     | `Live ->
        let* found = Runtime.Context.resolve context name in
        let* handle = Option.to_result ~none:(Error.unknown_relation name) found in
        Fun.protect
          ~finally:(fun () -> Protocols.Handle.release handle)
          (fun () ->
            let* enumerable = Protocols.Enumerable.require handle in
            Protocols.Enumerable.enumerate enumerable context)

class evaluator = object (self)
  inherit Kernel.Lifecycle.null
  inherit Kernel.Identity.of_id

  method invoke ~program context = execute context program
  method protocols : Protocols.Handle.protocol list = [Program.make self]
end

let make () = new evaluator |> Protocols.Handle.make
