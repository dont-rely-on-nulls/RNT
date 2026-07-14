open Rnt

let rec recursively_remove path =
  if Sys.is_directory path then
    begin
      Sys.readdir path
      |> Array.iter (fun name -> recursively_remove (Filename.concat path name));
      Unix.rmdir path
    end
  else
    Sys.remove path

let with_temporary_directory prefix ?(suffix = "") f =
  let path = Filename.temp_dir ~temp_dir:"/tmp" prefix suffix in
  Fun.protect
    (fun () -> f path)
    ~finally:(fun () -> recursively_remove path)

let condition_as_failure = function
  | Ok r -> r
  | Error c -> Alcotest.fail (Concepts.Condition.to_string_hum c)

let pp_value ppf v = Format.pp_print_string ppf (Concepts.Value.to_string v)
let value = Alcotest.testable pp_value Concepts.Value.equal
