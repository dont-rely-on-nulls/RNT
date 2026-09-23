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
    relation carrying enumerable answers the same members here. Refused
    when no declared mode generates under the attributes bound. *)
val generate : t Handle.interface -> binding -> (Handle.t, Concepts.Condition.condition) result

val nothing : binding
val bound : binding -> Concepts.Mode.attributes
val satisfies : binding -> Concepts.Tuple.t -> bool

(** membership for a relation with no lookup of its own, asked of the
    generator under the binding the tuple fixes. Only a tuple carrying
    exactly the [heading] can be a member, and it must match one whole. *)
class virtual membership : object
  val virtual heading : Concepts.Mode.attributes
  method virtual modes : (Concepts.Mode.t, Concepts.Condition.condition) result
  method virtual generate : binding -> (Handle.t, Concepts.Condition.condition) result
  method contains : Concepts.Tuple.t -> (bool, Concepts.Condition.condition) result
end
