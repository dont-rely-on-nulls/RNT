type t = string list

let this = []
let (@/) x y = x::y

let rec lookup handle = function
  | [] -> Ok (Some handle)
  | x::xs ->
     let open Utilities.Result in
     let open Protocols in
     match Protocols.Directory.from handle with
     | None -> Ok None
     | Some dir ->
        let* elem = Directory.find dir x in
        match elem with
        | None -> Ok None
        | Some elem -> lookup elem xs
