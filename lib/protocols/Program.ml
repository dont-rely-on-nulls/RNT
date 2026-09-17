module type PROGRAM = sig
  type t
end

module Make (P : PROGRAM) = struct
  class type implementation = object
    method invoke : P.t -> (Handle.t, Concepts.Condition.condition) result
  end

  type Handle.protocol += Program of implementation

  type t = implementation

  let make impl = Program (impl :> implementation)
  let from handle = Handle.into handle (function Program impl -> Some impl | _ -> None)
  let invoke i program = Handle.invoke i (fun o -> o#invoke program)
end
