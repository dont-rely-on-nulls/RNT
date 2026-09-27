type t = string list

let this = []
let ( @/ ) x y = x :: y

let to_string path =
  path
  |> List.map (fun x ->
      BatString.nreplace ~str:(BatString.nreplace ~str:x ~sub:"^" ~by:"^^") ~sub:"\\" ~by:"^\\" )
  |> BatIO.to_string (BatList.print ~first:"\\" ~last:"" ~sep:"\\" BatString.print)

module Error = struct
  open Concepts.Condition

  let path_not_found path =
    condition "path-not-found" "A given path was not found under the specified object"
      ("path" |=| Concepts.Value.String (to_string path))
end

let walking f g handle path =
  let rec walk handle = function
    | [] -> g handle
    | x :: xs -> (
        let open Utilities.Result in
        let open Protocols in
        let* dir =
          Handle.require Directory.from handle
          |> Result.map_error
               Concepts.Condition.(complement ("before-segment" |=| Concepts.Value.String x))
        in
        let* elem = Directory.find dir x in
        match elem with
        | None -> Error (Error.path_not_found path)
        | Some elem -> f x handle (fun () -> walk elem xs) )
  in
  walk handle path
  |> Result.map_error
       Concepts.Condition.(complement ("path" |=| Concepts.Value.String (to_string path)))

(* Handles we find in the middle of a walk get released once we're
   done with them, but never the caller's root.  If you leak one and
   its refcount never drops, nothing under that path gets collected,
   and an exclusive object, like a session, stays locked forever. *)
let releasing root handle f =
  Fun.protect ~finally:(fun () -> if handle != root then Protocols.Handle.release handle) f

let lookup handle path = walking (fun _ parent -> releasing handle parent) Result.ok handle path

let update handle path key reference value =
  let open Utilities.Result in
  let open Protocols in
  let* target = lookup handle path in
  releasing handle target (fun () ->
      let* registry = Handle.require Registry.from target in
      Registry.update registry key reference value )

let assoc handle path key value =
  let open Utilities.Result in
  let open Utilities.Fun in
  let open Protocols in
  let assoc_on handle key value =
    let* a = Handle.require Associative.from handle in
    let* a' = Associative.update a key value in
    Ok (Handle.from a')
  in
  walking
    (fun key dir f ->
      releasing handle dir (fun () -> f () |> fmap (assoc_on dir key |.| Option.some)) )
    (fun h -> releasing handle h (fun () -> assoc_on h key value))
    handle path
