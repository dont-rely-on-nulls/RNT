type t

(** values fixed for some of a relation's attributes, the attributes
    absent from it being the ones left free. *)
type binding = Concepts.Value.value BatMap.String.t

class type implementation = object
  method modes : (Concepts.Mode.t, Concepts.Condition.condition) result
  method generate : binding -> (Handle.t, Concepts.Condition.condition) result
end

val make : #implementation -> Handle.protocol
val from : Handle.t -> t Handle.interface option
val require : Handle.t -> (t Handle.interface, Concepts.Condition.condition) result
val modes : t Handle.interface -> (Concepts.Mode.t, Concepts.Condition.condition) result

(** a handle carrying a cursor over the members agreeing with the
    binding and under the empty binding this is enumeration, so a
    relation carrying enumerable answers the same members here. *)
val generate : t Handle.interface -> binding -> (Handle.t, Concepts.Condition.condition) result

val nothing : binding
val bound : binding -> Concepts.Mode.attributes
val satisfies : binding -> Concepts.Tuple.t -> bool
