type multigroup_description = string BatMap.String.t
type relation_description = string BatMap.String.t
type tuple_description = {relation: relation_description; attributes: string BatMap.String.t}

(* TODO: For now the description is completely detached from actual
   types and domains. Later figure out a way to represent the links
   without strings. *)
type description =
  | Multigroup of multigroup_description
  | Relation of relation_description
  | Tuple of tuple_description

class type implementation = object
  method describe : unit -> (description, Concepts.Condition.condition) result
end

type Handle.protocol += Schematics of implementation

type t = implementation

let make impl = Schematics (impl :> implementation)
let from handle =
  Handle.into handle (function Schematics impl -> Some impl | _ -> None)
let describe impl = Handle.invoke impl (fun o -> o#describe ())
