module Error = struct
  open Concepts.Condition

  let unknown_relation name =
    condition "unknown-relation" "A plan named a relation that does not exist under this snapshot"
      ("name" |=| Concepts.Value.String name)

  let cancelled () =
    condition "evaluation-cancelled" "An evaluation was stopped before it produced its result" empty
end

type plan = Base of Protocols.Handle.t
          | Project of plan * string BatFingerTree.t

module Program = Protocols.Program.Make (struct
  type t = plan
end)

let execute =
  let open Utilities.Result in
  function
  | Base relation_handle ->
     Fun.protect
       ~finally:(fun () -> Protocols.Handle.release relation_handle)
       (fun () ->
         let* enumerable = Protocols.Enumerable.require relation_handle in
         Protocols.Enumerable.enumerate enumerable)
  | Project (_plan, _attributes) -> failwith "TODO"

class evaluator = object (self)
  inherit Kernel.Lifecycle.null
  inherit Kernel.Identity.of_id

  method invoke = execute
  method protocols : Protocols.Handle.protocol list = [Program.make self]
end

let make () = new evaluator |> Protocols.Handle.make
