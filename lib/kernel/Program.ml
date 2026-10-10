(* A program is an image just like PE, but we represent it as an
   object. It should have the kind of executable it is, indicating the
   evaluator needed for it to be executed and a type (generally it can
   be a tree) that can be interpreted/compiled by said evaluator, and
   finally the source code in plain text so we can display it for
   debug. We can persist programs under
   \system\branch\<b>\multigroup\<m>\program\, but we are not
   obligated to, they can be merely temporary in memory. *)

module Error = struct
  open Concepts.Condition

  let unloaded evaluator =
    condition "unloaded-program" "A program has to be given a root before it can be run"
      ("evaluator" |=| Concepts.Value.String evaluator)

  let no_evaluator evaluator =
    condition "no-evaluator" "No evaluator is registered under that name"
      ("evaluator" |=| Concepts.Value.String evaluator)
end

type kind = Protocols.Evaluator.kind = ..
type image = {evaluator: string; kind: kind; source: string}
type Protocols.Handle.protocol += Program of image

let image handle =
  Protocols.Handle.into handle (function Program image -> Some image | _ -> None)
  |> Option.map (fun i -> Protocols.Handle.invoke i Fun.id)

let reference evaluator =
  match String.rindex_opt evaluator ':' with
  | None -> "system", evaluator
  | Some i ->
      String.sub evaluator 0 i, String.sub evaluator (i + 1) (String.length evaluator - i - 1)

let lookup root evaluator =
  let scope, language = reference evaluator in
  Path.lookup root Path.(scope @/ "evaluator" @/ language @/ this)
  |> Result.map_error (fun _ -> Error.no_evaluator evaluator)

class program ?root image =
  object (self)
    inherit Lifecycle.null
    inherit Identity.of_id
    method to_string = image.source

    method invoke inputs ~within =
      let open Utilities.Result in
      let* root = Option.to_result ~none:(Error.unloaded image.evaluator) root in
      let* found = lookup root image.evaluator in
      Protocols.Handle.releasing found (fun () ->
          let* evaluator = Protocols.Evaluator.require found in
          Protocols.Evaluator.eval evaluator image.kind inputs ~within )

    method protocols : Protocols.Handle.protocol list =
      [Program image; Protocols.Executable.make self]
  end

let make ?root ~evaluator ~source kind =
  new program ?root {evaluator; kind; source} |> Protocols.Handle.make
