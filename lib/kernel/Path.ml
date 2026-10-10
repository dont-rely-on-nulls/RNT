type t = string list

let this = []
let ( @/ ) x y = x :: y
let of_list segments = segments
let to_list path = path

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
  let open Protocols in
  let open Utilities.Result in
  let rec walk handle = function
    | [] -> g (Handle.keep handle)
    | x :: xs -> (
        let* dir =
          Handle.require Directory.from handle
          |> Result.map_error
               Concepts.Condition.(complement ("before-segment" |=| Concepts.Value.String x))
        in
        let* elem = Directory.find dir x |> Result.map (Option.map Handle.autorelease) in
        match elem with
        | None -> Error (Error.path_not_found path)
        | Some elem -> f x handle (fun () -> walk elem xs) )
  in
  Handle.with_autorelease (fun () ->
      walk handle path
      |> Result.map_error
           Concepts.Condition.(complement ("path" |=| Concepts.Value.String (to_string path))) )

let lookup handle path = walking (fun _ _ f -> f ()) Result.ok handle path

let update handle path key reference value =
  let open Utilities.Result in
  let open Protocols in
  let* target = lookup handle path in
  let* registry = Handle.require Registry.from target in
  Registry.update registry key reference value

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
    (fun key dir f -> f () |> fmap (assoc_on dir key |.| Option.some))
    (fun h -> assoc_on h key value)
    handle path
