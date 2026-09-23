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

  let exhaustible declaration =
    match Concepts.Mode.generation declaration BatSet.String.empty with
    | Some cardinality -> Concepts.Cardinality.exhaustible cardinality
    | None -> false

  (* A cursor holds a reference to its relation, so the edges it reads
     outlive a release of the relation that produced it. *)
  class retaining scan release_owner =
    object (self)
      inherit Lifecycle.counted
      inherit Identity.of_id

      method destroy =
        Protocols.Handle.release (Protocols.Handle.from scan);
        release_owner ()

      method fetch limit = Protocols.Cursor.fetch scan limit
      method protocols : Protocols.Handle.protocol list = [Protocols.Cursor.make self]
    end

  class ephemeral plan address declaration total edges =
    object (self)
      inherit Lifecycle.counted
      val plan : D.plan = plan
      method destroy = List.iter Protocols.Handle.release edges
      method predicate = Ok None
      method local_constraints = Ok None
      method modes = Ok declaration

      method private retained binding =
        let open Utilities.Result in
        let* cursor = D.generate plan binding in
        match Protocols.Cursor.require cursor with
        | Error c ->
            Protocols.Handle.release cursor;
            Error c
        | Ok scan ->
            ignore self#reference;
            Ok (new retaining scan (fun () -> self#release) |> Protocols.Handle.make)

      method generate binding = self#retained binding
      method enumerate = self#retained Protocols.Generative.nothing

      method describe () =
        D.describe plan |> Result.map (fun description -> Protocols.Schematics.Relation description)

      (* Membership of a derived relation is decided by the derivation
         and not by a lookup, so it is asked of the generator under the
         binding the tuple itself fixes. *)
      method contains (tuple : Concepts.Tuple.t) =
        let open Utilities.Result in
        let* cursor = D.generate plan tuple.Concepts.Tuple.attributes in
        Fun.protect
          ~finally:(fun () -> Protocols.Handle.release cursor)
          (fun () ->
            let* scan = Protocols.Cursor.require cursor in
            let* first = Protocols.Cursor.next scan in
            Ok (Option.is_some first) )

      method protocols : Protocols.Handle.protocol list =
        let carried =
          [ Protocols.Relation.make self;
            Protocols.Schematics.make self;
            Protocols.Generative.make self ]
        in
        if total then Protocols.Enumerable.make self :: carried else carried

      method hash : Concepts.Hash.hash = address
    end

  let derive ?pinned ?(edges = []) plan =
    let open Utilities.Result in
    let* declaration = D.modes plan in
    Ok
      ( new ephemeral plan (identity ?pinned plan) declaration (exhaustible declaration) edges
      |> Protocols.Handle.make )
end
