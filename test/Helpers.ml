open Rnt

let rec recursively_remove path =
  if Sys.is_directory path then begin
    Sys.readdir path |> Array.iter (fun name -> recursively_remove (Filename.concat path name));
    Unix.rmdir path
  end
  else Sys.remove path

let with_temporary_directory prefix ?(suffix = "") f =
  let path = Filename.temp_dir ~temp_dir:"/tmp" prefix suffix in
  Fun.protect (fun () -> f path) ~finally:(fun () -> recursively_remove path)

let condition_as_failure = function
  | Ok r -> r
  | Error c -> Alcotest.fail (Concepts.Condition.to_string_hum c)

let pp_value ppf v = Format.pp_print_string ppf (Concepts.Value.to_string v)
let value = Alcotest.testable pp_value Concepts.Value.equal

module Storage = struct
  module type CONFIGURATOR = sig
    val configure : string -> Rnt.Concepts.Configuration.term
  end

  module LMDB_Configurator : CONFIGURATOR = struct
    let configure base =
      let open Sexplib.Sexp in
      List [Atom "lmdb"; List [Atom "path"; Atom base]; List [Atom "mode"; Atom "420"]]
      |> Rnt.Concepts.Configuration.term_of_sexp
  end

  module Make (S : Abstract.Storage.STORAGE) (C : CONFIGURATOR) = struct
    let with_connection f dir () =
      with_temporary_directory dir begin fun dir ->
          begin
            let open Utilities.Result in
            let* conn = S.connect (C.configure dir) in
            Ok (f conn)
          end
          |> condition_as_failure
        end
  end
end
