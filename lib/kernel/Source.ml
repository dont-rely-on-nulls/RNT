let blob text = Concepts.Blob.blob_of_bytes (Bytes.of_string text)

let stored_text ~language text =
  EphemeralRelation.Stored {evaluator= language; code= blob text; name= None}

let program ~language text = Prototype.mixture [stored_text ~language text]

let view ~language ~heading text =
  Prototype.mixture
    [ stored_text ~language text;
      Protocols.Schematics.make
        object
          method describe () = Ok (Protocols.Schematics.Relation heading)
        end ]

let stored handle =
  EphemeralRelation.stored handle
  |> Option.map (fun (evaluator, code, name) ->
      evaluator, Bytes.to_string (Concepts.Blob.bytes_of_blob code), name )

let text handle = Option.map (fun (evaluator, text, _) -> evaluator, text) (stored handle)

let reference evaluator =
  match String.rindex_opt evaluator ':' with
  | None -> "system", evaluator
  | Some i ->
      String.sub evaluator 0 i, String.sub evaluator (i + 1) (String.length evaluator - i - 1)

let language_of evaluator = snd (reference evaluator)

module Error = struct
  open Concepts.Condition

  let not_a_program language =
    condition "not-a-program" "An evaluator was given something that carries no source"
      ("language" |=| Concepts.Value.String language)

  let foreign language given =
    condition "foreign-program" "An evaluator was given source in another language"
      ("language" |=| Concepts.Value.String language & "given" |=| Concepts.Value.String given)

  let no_evaluator evaluator =
    condition "no-evaluator" "No evaluator is registered under that name"
      ("evaluator" |=| Concepts.Value.String evaluator)
end

let evaluator ~language ?view run =
  Protocols.Handle.make
    object (self)
      inherit Lifecycle.null
      inherit Identity.of_id
      method to_string = language ^ "-evaluator"
      method protocols : Protocols.Handle.protocol list = [Protocols.Evaluator.make self]

      method invoke program ~within =
        match stored program with
        | None -> Error (Error.not_a_program language)
        | Some (given, _, _) when language_of given <> language ->
            Error (Error.foreign language given)
        | Some (_, source, name) -> (
          match name, view with
          | Some name, Some view -> view ~within ~name source
          | _ -> run ~within source )
    end

let evaluators scope = Path.(scope @/ "evaluator" @/ this)

let bind root ~within evaluator program =
  let open Utilities.Result in
  let scope, language = reference evaluator in
  let* found =
    Result.bind
      (Path.lookup root (evaluators scope))
      (fun directory -> Path.lookup directory Path.(language @/ this))
    |> Result.map_error (fun _ -> Error.no_evaluator evaluator)
  in
  Fun.protect
    ~finally:(fun () -> Protocols.Handle.release found)
    (fun () ->
      let* found = Protocols.Evaluator.require found in
      Protocols.Evaluator.invoke found program ~within )

let run root ~language ~within source = bind root ~within language (program ~language source)

let register root ~scope ~language evaluator =
  let open Utilities.Result in
  let* directory = Path.lookup root (evaluators scope) in
  let* registry = Protocols.Handle.require Protocols.Registry.from directory in
  let* _ = Protocols.Registry.update registry language None (Some evaluator) in
  Ok ()
