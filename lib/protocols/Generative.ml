module Error = struct
  open Concepts.Condition

  let not_generative () =
    condition "not-generative"
      "A relation was used where the expression must produce members under a binding, but it \
       declares no modes. A relation that cannot be asked this way can still be reached through \
       another access path."
      empty
end

type binding = Concepts.Value.value BatMap.String.t

class type implementation = object
  method modes : (Concepts.Mode.t, Concepts.Condition.condition) result
  method generate : binding -> (Handle.t, Concepts.Condition.condition) result
end

type Handle.protocol += Generative of implementation
type t = implementation

let make impl = Generative (impl :> implementation)
let from handle = Handle.into handle (function Generative impl -> Some impl | _ -> None)
let require handle = from handle |> Option.to_result ~none:(Error.not_generative ())
let modes i = Handle.invoke i (fun o -> o#modes)
let generate i binding = Handle.invoke i (fun o -> o#generate binding)
let nothing = BatMap.String.empty
let bound binding = BatMap.String.keys binding |> BatSet.String.of_enum

let satisfies binding tuple =
  BatMap.String.for_all
    (fun attribute value ->
      match BatMap.String.find_opt attribute tuple.Concepts.Tuple.attributes with
      | Some found -> Concepts.Value.equal found value
      | None -> false )
    binding
