module type DERIVATION = sig
  type plan

  val identity : plan -> Concepts.Hash.hash

  val describe :
    plan -> (Protocols.Schematics.relation_description, Concepts.Condition.condition) result

  val modes : plan -> (Concepts.Mode.t, Concepts.Condition.condition) result

  val generate :
    plan ->
    Protocols.Generative.binding ->
    (Protocols.Handle.t, Concepts.Condition.condition) result
end

module Make (D : DERIVATION) = struct
  let pinned_tag = "rnt/pinned/1"

  let identity ?pinned plan =
    let derivation = D.identity plan in
    match pinned with
    | None -> derivation
    | Some branch ->
        pinned_tag ^ Concepts.Hash.to_raw_string derivation ^ Concepts.Hash.to_raw_string branch
        |> Bytes.of_string
        |> Concepts.Hash.hash_of_bytes

  class ephemeral (plan : D.plan) address declaration description edges =
    object (self)
      inherit Lifecycle.counted
      inherit Protocols.Generative.membership
      val heading = Concepts.Mode.attributes_of_map description
      method destroy = List.iter Protocols.Handle.release edges
      method predicate = Ok None
      method local_constraints = Ok None
      method modes = Ok declaration

      (* A cursor holds a reference to its relation, so the edges it reads
         outlive a release of the relation that produced it. *)
      method generate binding =
        D.generate plan binding
        |> Result.map (fun cursor ->
               new Lifecycle.retaining cursor (self :> Lifecycle.lifecycle) |> Protocols.Handle.make )

      method enumerate = self#generate Protocols.Generative.nothing
      method describe () = Ok (Protocols.Schematics.Relation description)

      method protocols : Protocols.Handle.protocol list =
        let carried =
          [ Protocols.Relation.make self;
            Protocols.Schematics.make self;
            Protocols.Generative.make self ]
        in
        if Concepts.Mode.exhaustible declaration BatSet.String.empty then
          Protocols.Enumerable.make self :: carried
        else carried

      method hash : Concepts.Hash.hash = address
    end

  let derive ?pinned ?(edges = []) plan =
    let open Utilities.Result in
    let derived =
      let* declaration = D.modes plan in
      let* description = D.describe plan in
      Ok
        ( new ephemeral plan (identity ?pinned plan) declaration description edges
        |> Protocols.Handle.make )
    in
    Result.iter_error (fun _ -> List.iter Protocols.Handle.release edges) derived;
    derived
end
