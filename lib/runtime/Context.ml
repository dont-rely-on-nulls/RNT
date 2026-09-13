module Error = struct
  open Concepts.Condition

  let not_a_directory segment =
    condition "not-a-directory" "A path segment named an object with no Directory protocol"
      ("segment" |=| Concepts.Value.String segment)
end

let resolve { Protocols.Context.root; _ } name =
  let open Utilities.Result in
  let rec walk handle = function
    | [] -> Ok (Protocols.Handle.copy handle)
    | segment :: rest ->
       let* directory =
         Protocols.Directory.from handle
         |> Option.to_result ~none:(Error.not_a_directory segment)
       in
       let* found = Protocols.Directory.find directory segment in
       match found with
       | None -> Ok None
       | Some child ->
          Fun.protect ~finally:(fun () -> Protocols.Handle.release child)
            (fun () -> walk child rest)
  in
  String.split_on_char '/' name |> List.filter (fun segment -> segment <> "") |> walk root

let over ~snapshot ~root ?(cancelled = fun () -> false) () =
  { Protocols.Context.snapshot
  ; root
  ; status = (fun () -> if cancelled () then `Cancelled else `Live) }
