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
  module Error = struct
    open Concepts.Condition

    let attributes bound = Concepts.Value.String (String.concat ", " (BatSet.String.elements bound))

    let ungenerable bound =
      condition "ungenerable-binding"
        "The derivation declares no mode that generates under the attributes bound."
        ("bound" |=| attributes bound)

    let undecidable bound =
      condition "undecidable-membership"
        "The derivation declares no mode that decides membership under the attributes of the tuple."
        ("bound" |=| attributes bound)
  end

  let pinned_tag = "rnt/pinned/1"

  let identity ?pinned plan =
    let derivation = D.identity plan in
    match pinned with
    | None -> derivation
    | Some branch ->
        pinned_tag ^ Concepts.Hash.to_raw_string derivation ^ Concepts.Hash.to_raw_string branch
        |> Bytes.of_string
        |> Concepts.Hash.hash_of_bytes

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

  class ephemeral (plan : D.plan) address declaration description edges =
    object (self)
      inherit Lifecycle.counted
      val heading = BatMap.String.keys description |> BatSet.String.of_enum
      method destroy = List.iter Protocols.Handle.release edges
      method predicate = Ok None
      method local_constraints = Ok None
      method modes = Ok declaration

      method generate binding =
        let open Utilities.Result in
        let bound = Protocols.Generative.bound binding in
        let* () =
          if Option.is_some (Concepts.Mode.generation declaration bound) then Ok ()
          else Error (Error.ungenerable bound)
        in
        let* cursor = D.generate plan binding in
        match Protocols.Cursor.require cursor with
        | Error c ->
            Protocols.Handle.release cursor;
            Error c
        | Ok scan ->
            ignore self#reference;
            Ok (new retaining scan (fun () -> self#release) |> Protocols.Handle.make)

      method enumerate = self#generate Protocols.Generative.nothing
      method describe () = Ok (Protocols.Schematics.Relation description)

      (* Membership of a derived relation is decided by the derivation
         and not by a lookup, so it is asked of the generator under the
         binding the tuple itself fixes. Only a tuple carrying exactly the
         described attributes can be a member, and it must match one whole. *)
      method contains (tuple : Concepts.Tuple.t) =
        let open Utilities.Result in
        let binding = tuple.Concepts.Tuple.attributes in
        let bound = Protocols.Generative.bound binding in
        if not (BatSet.String.equal heading bound) then Ok false
        else
          let* () =
            if Concepts.Mode.decision declaration bound then Ok () else Error (Error.undecidable bound)
          in
          let* cursor = D.generate plan binding in
          let expected = Concepts.Tuple.hash tuple in
          Fun.protect
            ~finally:(fun () -> Protocols.Handle.release cursor)
            (fun () ->
              let* scan = Protocols.Cursor.require cursor in
              let rec seek () =
                let* found = Protocols.Cursor.next scan in
                match found with
                | None -> Ok false
                | Some member ->
                    if Concepts.Hash.hash_equals (Concepts.Tuple.hash member) expected then Ok true
                    else seek ()
              in
              seek () )

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
