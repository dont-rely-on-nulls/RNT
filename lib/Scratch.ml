module LMDB = Backend.Storage.LMDB
module I = Kernel.Initialization.Make (LMDB)

let rec remove path =
  if Sys.is_directory path then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Sys.rmdir path
  end
  else Sys.remove path

let root ?(evaluators = ["fol", Evaluators.FOL.make ()]) () =
  let open Utilities.Result in
  let directory = Filename.temp_dir "rnt-scratch" "" in
  let* connection =
    Sexplib.Sexp.(
      List [Atom "lmdb"; List [Atom "path"; Atom directory]; List [Atom "mode"; Atom "420"]] )
    |> Concepts.Configuration.term_of_sexp
    |> LMDB.connect
  in
  at_exit (fun () ->
      LMDB.disconnect connection;
      try remove directory with Sys_error _ -> () );
  I.initialize ~evaluators connection
