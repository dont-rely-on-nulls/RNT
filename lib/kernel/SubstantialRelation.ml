module Make (S : Abstract.Storage.STORAGE) = struct
  module SI = Storage.Make (S)

  module Error = struct
    open Concepts.Condition

    let malformed_relation () =
      condition "malformed-substantial-relation"
        "The on-disk representation of a substantial relation did not conform to what was \
         expected. Is your database corrupted?"
        empty

    let malformed_tuple_key length =
      condition "malformed-tuple-key" "A tuple key did not have the expected hash size"
        ("length" |=| Concepts.Value.Integer length)

    let invalid_tuple_root root =
      condition "invalid-tuple-root"
        "The tuple-set root for a substantial relation is missing from the backend. Either your \
         storage is corrupted, or this is a bug in RNT!"
        ("hash" |=| Concepts.Value.String (Concepts.Hash.to_hum_string root))
  end

  module TupleKey = struct
    type t = Concepts.Hash.hash

    let encode = Concepts.Hash.blob_of_hash

    let decode blob =
      let raw = Concepts.Blob.bytes_of_blob blob |> Bytes.to_string in
      if String.length raw = Concepts.Hash.size then Ok (Concepts.Hash.of_raw_string raw)
      else Error (Error.malformed_tuple_key (String.length raw))

    let compare = Concepts.Hash.compare
  end

  module TupleValue = struct
    type t = Concepts.Tuple.t

    let encode = Concepts.Tuple.Representation.to_blob
    let decode = Concepts.Tuple.Representation.of_blob
  end

  module TupleSet = Merkle.Interface (S) (TupleKey) (TupleValue)

  type t =
    { schematics: Concepts.Hash.hash;
      predicate: Concepts.Hash.hash option;
      local_constraints: Concepts.Hash.hash option;
      tuples: TupleSet.address;
      indexes: Concepts.Hash.hash option }

  module rec Representation : (Concepts.Encoding.Record.S with type t = t) =
    Concepts.Encoding.Record.Make (Body)

  and Body : Concepts.Encoding.Record.BODY = struct
    type nonrec t = t

    let tag = 'R'
    let malformed = Error.malformed_relation

    let fields {schematics; predicate; local_constraints; tuples; indexes} =
      let open Concepts.Encoding in
      [ "schema", Value.bencode_of_hash schematics;
        "predicate", Value.bencode_of_option Value.bencode_of_hash predicate;
        "local-constraints", Value.bencode_of_option Value.bencode_of_hash local_constraints;
        "tuples", Value.bencode_of_hash tuples;
        "indexes", Value.bencode_of_option Value.bencode_of_hash indexes ]

    let of_fields fields =
      let open Utilities.Result in
      let open Concepts.Encoding in
      let* schematics = Bencode.field "schema" fields |> fmap Value.hash_of_bencode in
      let* predicate =
        Bencode.field "predicate" fields |> fmap (Value.option_of_bencode Value.hash_of_bencode)
      in
      let* local_constraints =
        Bencode.field "local-constraints" fields
        |> fmap (Value.option_of_bencode Value.hash_of_bencode)
      in
      let* tuples = Bencode.field "tuples" fields |> fmap Value.hash_of_bencode in
      let* indexes =
        Bencode.field "indexes" fields |> fmap (Value.option_of_bencode Value.hash_of_bencode)
      in
      Ok {schematics; predicate; local_constraints; tuples; indexes}
  end

  let encode = Representation.to_blob
  let decode = Representation.of_blob

  let schematics {schematics; _} = schematics
  let predicate {predicate; _} = predicate
  let local_constraints {local_constraints; _} = local_constraints
  let tuples {tuples; _} = tuples
  let indexes {indexes; _} = indexes
  let hash relation = Representation.to_blob relation |> Concepts.Hash.hash_of_blob

  let tuple_node tx relation =
    let open Utilities.Result in
    let* tuples = TupleSet.find tx relation.tuples in
    Option.to_result ~none:(Error.invalid_tuple_root relation.tuples) tuples

  let empty tx ~schematics ?predicate ?local_constraints ?indexes () =
    let open Utilities.Result in
    let* tuples = TupleSet.empty_under tx in
    Ok {schematics; predicate; local_constraints; tuples; indexes}

  let store tx relation = SI.store_blob tx (Representation.to_blob relation)

  let contains_tuple tx relation tuple =
    let open Utilities.Result in
    let* node = tuple_node tx relation in
    TupleSet.mem tx (Concepts.Tuple.hash tuple) node

  let schema_of tx relation =
    let open Utilities.Result in
    let* data = SI.get_req tx (S.Hash relation.schematics) in
    let* fields = Concepts.Encoding.Bencode.of_blob data in
    let* kvs = Concepts.Encoding.Bencode.as_dict fields in
    kvs
    |> List.map (fun (name, domain) ->
           Concepts.Encoding.Bencode.as_string domain
           |> Result.map (fun domain ->
                  (name, {Protocols.Schematics.domain; provenance= []}) ) )
    |> Utilities.List.sequence
    |> Result.map (fun kvs ->
           List.fold_left
             (fun acc (name, attribute) -> BatMap.String.add name attribute acc)
             BatMap.String.empty kvs)

  let scan storage relation ~keep =
    let open Utilities.Result in
    let* tx = S.start_read storage in
    let closed = ref false in
    let close () = if not !closed then begin closed := true; ignore (S.abort tx) end in
    let* node = tuple_node tx relation |> Result.map_error (fun c -> close (); c) in
    (* The fold is suspended by [yield], so the tree is walked one node
       and one tuple at a time rather than materialized before the
       first tuple is produced. *)
    let produce ~yield =
      let walked = TupleSet.iter tx (fun _ tuple -> if keep tuple then yield tuple) node in
      close ();
      walked
    in
    Ok (Generator.cursor_of ~on_release:close produce)

  let enumerate storage relation = scan storage relation ~keep:(fun _ -> true)

  let generate storage relation binding =
    scan storage relation ~keep:(Protocols.Generative.satisfies binding)

  let modes tx relation =
    let open Utilities.Result in
    let* description = schema_of tx relation in
    let labels = BatMap.String.keys description |> BatList.of_enum in
    Ok
      (Concepts.Mode.of_list
         [ Concepts.Mode.enumerable Concepts.Cardinality.Finite;
           Concepts.Mode.decides_when labels ] )

  class relation storage value declaration =
    object (self)
      inherit Lifecycle.null
      val storage : S.connection = storage
      val relation : t = value
      method predicate = Ok relation.predicate
      method local_constraints = Ok relation.local_constraints

      (* The protocol takes a tuple, not bytes: encoding is this object's business, and a caller
         that had to produce the exact stored bytes would have to know this encoding to do it. *)
      method contains (tuple : Concepts.Tuple.t) =
        SI.with_transaction storage (fun tx -> contains_tuple tx relation tuple)

      method describe () =
        let open Utilities.Result in
        let* description = SI.with_transaction storage (fun tx -> schema_of tx relation) in
        Ok (Protocols.Schematics.Relation description)

      (* A substantial relation is finitely enumerable, so it carries [Enumerable] as well as
         [Relation]. A procedural relation would carry only the latter, which is how an evaluator
         discovers it cannot iterate one -- see [Protocols.Enumerable]. The context is accepted and
         unused here: this enumeration reads through its own cursor-lifetime transaction and needs
         no name resolution, but cancellation should eventually be checked between tuples. *)
      method enumerate = enumerate storage relation

      method modes : (Concepts.Mode.t, Concepts.Condition.condition) result = Ok declaration
      method generate binding = generate storage relation binding

      method protocols : Protocols.Handle.protocol list =
        [ Protocols.Relation.make self
        ; Protocols.Enumerable.make self
        ; Protocols.Generative.make self
        ; Protocols.Schematics.make self ]
      method hash = hash relation
    end

  (* Modes follow from the schema alone, which a relation never changes,
     so they are read once here rather than on every request. *)
  let instantiate tx conn relation =
    let open Utilities.Result in
    let* declaration = modes tx relation in
    Ok (new relation conn relation declaration |> Protocols.Handle.make)

  let make conn ~schematics ?predicate ?local_constraints ?indexes () =
    let open Utilities.Result in
    SI.with_transaction conn (fun tx ->
        let* relation = empty tx ~schematics ?predicate ?local_constraints ?indexes () in
        let* _ = store tx relation in
        instantiate tx conn relation )

  let load_value tx addr =
    let open Utilities.Result in
    let* data = SI.get_req tx (S.Hash addr) in
    Representation.of_blob data

  let wrap conn relation = SI.with_transaction conn (fun tx -> instantiate tx conn relation)

  let load tx conn addr =
    load_value tx addr |> Utilities.Result.fmap (instantiate tx conn)

  let assert_tuple tx relation tuple =
    let open Utilities.Result in
    let* node = tuple_node tx relation in
    let* node = TupleSet.insert tx (Concepts.Tuple.hash tuple) tuple node in
    Ok {relation with tuples= TupleSet.hash_of node}
end
