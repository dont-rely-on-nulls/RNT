module type DERIVATION = sig
  type plan

  (** the hash of the plan, taken over the branch-local names of its
      inputs rather than over their content addresses. The idea is to
      have the same expression denote one object on every branch and
      at every point in time. *)
  val identity : plan -> Concepts.Hash.hash

  val describe :
    plan -> (Protocols.Schematics.relation_description, Concepts.Condition.condition) result

  val modes : plan -> (Concepts.Mode.t, Concepts.Condition.condition) result

  val generate :
    plan ->
    Protocols.Generative.binding ->
    (Protocols.Handle.t, Concepts.Condition.condition) result
end

module Make (D : DERIVATION) : sig
  (** unpinned, the identity of the derivation itself; pinned to a
      branch commit, the identity of that derivation against one
      reconstructible state, which is the only form for which equal
      identity implies equal extension. *)
  val identity : ?pinned:Concepts.Hash.hash -> D.plan -> Concepts.Hash.hash

  (** edges are the handles the derivation reads, which are released
      when the relation is also. Rejection of a derivation surfaces
      here instead of when a cursor is being drained. *)
  val derive :
    ?pinned:Concepts.Hash.hash ->
    ?edges:Protocols.Handle.t list ->
    D.plan ->
    (Protocols.Handle.t, Concepts.Condition.condition) result
end
