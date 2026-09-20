type t

(* TODO: For now the description is completely detached from actual
   types and domains. Later figure out a way to represent the links
   without strings. *)
type multigroup_description = string BatMap.String.t

(** where an attribute comes from with the path relation and the
    attribute it has. *)
type origin = {source: string list; attribute: string}

(** an attribute of a derived relation may be for several occurrences
    at once, for example in a natural join. So its provenance is a
    collection. *)
type attribute_description = {domain: string; provenance: origin list}

type relation_description = attribute_description BatMap.String.t
type tuple_description = {relation: relation_description; attributes: string BatMap.String.t}

type description =
  | Multigroup of multigroup_description
  | Relation of relation_description
  | Tuple of tuple_description

class type implementation = object
  method describe : unit -> (description, Concepts.Condition.condition) result
end

val make : #implementation -> Handle.protocol
val from : Handle.t -> t Handle.interface option
val describe : t Handle.interface -> (description, Concepts.Condition.condition) result
