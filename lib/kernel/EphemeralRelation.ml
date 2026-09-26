type t =
  { schematics: [`Persisted of Concepts.Hash.hash
               | `Temporary of (Protocols.Schematics.attribute_description BatMap.String.t) ] }

module Error = struct
  open Concepts.Condition
  let local_constraint_not_implemented =
    condition "local-constraint-not-implemented"
      "Local constraints have no centralized authority for their discerniment and enforcement yet."
      empty
  let predicate_not_implemented =
    condition "predicate-not-implemented"
      "Preciate descriptions for relations is not designed yet."
      empty
end

class ephemeral_relation program address value =
  object (self)
    inherit Lifecycle.null
    val relation : t = value
    method local_constraints = Error Error.local_constraint_not_implemented
    method predicate = Error Error.predicate_not_implemented

    method protocol : Protocols.Handle.protocol list =
      Protocols.[ Relation.make self
                ; Enumerable.make self
                ; Schematics.make self ]
    method hash : Concepts.Hash.hash = address
  end
