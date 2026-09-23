module Error = struct
  open Concepts.Condition

  let not_generative () =
    condition "not-generative"
      "A relation was used where the expression must produce members under a binding, but it \
       declares no modes. A relation that cannot be asked this way can still be reached through \
       another access path."
      empty

  let attributes bound = Concepts.Value.String (String.concat ", " (BatSet.String.elements bound))

  let ungenerable bound =
    condition "ungenerable-binding"
      "The relation declares no mode that generates under the attributes bound."
      ("bound" |=| attributes bound)

  let undecidable bound =
    condition "undecidable-membership"
      "The relation declares no mode that decides membership under the attributes of the tuple."
      ("bound" |=| attributes bound)
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
let nothing = BatMap.String.empty
let bound = Concepts.Mode.attributes_of_map
let modes i = Handle.invoke i (fun o -> o#modes)

let generate i binding =
  Handle.invoke i (fun o ->
      let open Utilities.Result in
      let bound = bound binding in
      let* declaration = o#modes in
      if Option.is_some (Concepts.Mode.generation declaration bound) then o#generate binding
      else Error (Error.ungenerable bound) )

let satisfies binding tuple =
  BatMap.String.for_all
    (fun attribute value ->
      match BatMap.String.find_opt attribute tuple.Concepts.Tuple.attributes with
      | Some found -> Concepts.Value.equal found value
      | None -> false )
    binding

class virtual membership =
  object (self)
    val virtual heading : Concepts.Mode.attributes
    method virtual modes : (Concepts.Mode.t, Concepts.Condition.condition) result
    method virtual generate : binding -> (Handle.t, Concepts.Condition.condition) result

    method contains (tuple : Concepts.Tuple.t) =
      let open Utilities.Result in
      let binding = tuple.Concepts.Tuple.attributes in
      let bound = bound binding in
      if not (BatSet.String.equal heading bound) then Ok false
      else
        let* declaration = self#modes in
        let* () =
          if Concepts.Mode.decision declaration bound then Ok () else Error (Error.undecidable bound)
        in
        let* cursor = self#generate binding in
        let expected = Concepts.Tuple.hash tuple in
        Fun.protect
          ~finally:(fun () -> Handle.release cursor)
          (fun () ->
            let* scan = Cursor.require cursor in
            Cursor.exists scan (fun member ->
                Concepts.Hash.hash_equals (Concepts.Tuple.hash member) expected ) )
  end
