let program ~language text =
  Prototype.mixture
    [ EphemeralRelation.Stored
        {evaluator= language; code= Concepts.Blob.blob_of_bytes (Bytes.of_string text)} ]

let text handle =
  Protocols.Handle.into handle (function
    | EphemeralRelation.Stored {evaluator; code} ->
        Some (evaluator, Bytes.to_string (Concepts.Blob.bytes_of_blob code))
    | _ -> None )
  |> Option.map (fun i -> Protocols.Handle.invoke i Fun.id)

module Error = struct
  open Concepts.Condition

  let not_a_program language =
    condition "not-a-program" "An evaluator was given something that carries no source"
      ("language" |=| Concepts.Value.String language)

  let foreign language given =
    condition "foreign-program" "An evaluator was given source in another language"
      ("language" |=| Concepts.Value.String language & "given" |=| Concepts.Value.String given)

  let no_evaluator language =
    condition "no-evaluator" "No evaluator is registered for the language"
      ("language" |=| Concepts.Value.String language)
end

let evaluator ~language run =
  Protocols.Handle.make
    object (self)
      inherit Lifecycle.null
      inherit Identity.of_id
      method to_string = language ^ "-evaluator"
      method protocols : Protocols.Handle.protocol list = [Protocols.Evaluator.make self]

      method invoke program =
        match text program with
        | None -> Error (Error.not_a_program language)
        | Some (given, _) when given <> language -> Error (Error.foreign language given)
        | Some (_, source) -> run source
    end

let run root ~language source =
  let open Utilities.Result in
  let* evaluator =
    Path.lookup root Path.("evaluator" @/ language @/ this)
    |> Result.map_error (fun _ -> Error.no_evaluator language)
  in
  let* evaluator = Protocols.Evaluator.require evaluator in
  Protocols.Evaluator.invoke evaluator (program ~language source)

let register root ~language evaluator =
  let open Utilities.Result in
  let* evaluators = Path.lookup root Path.("evaluator" @/ this) in
  let* registry = Protocols.Handle.require Protocols.Registry.from evaluators in
  let* _ = Protocols.Registry.update registry language None (Some evaluator) in
  Ok ()
