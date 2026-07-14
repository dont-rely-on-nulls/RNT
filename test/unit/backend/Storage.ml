module type CONFIGURATOR = sig
  val configure: string -> Rnt.Concepts.Configuration.term
end

module Make (S: Rnt.Abstract.Storage.STORAGE) (C: CONFIGURATOR) = struct
  open Alcotest

  let with_connection f () =
    Helpers.with_temporary_directory "storage-test"
      (fun dir ->
        begin
          let open Rnt.Utilities.Result in
          let* conn = S.connect (C.configure dir) in
          Ok (f conn)
        end
        |> Helpers.condition_as_failure)

  let storage_and_retrieval _conn =
    fail "nope"

  let suite prefix = ("storage/" ^ prefix), [test_case "storage-and-retrieval" `Quick (with_connection storage_and_retrieval)]
end

module LMDB_Configurator: CONFIGURATOR = struct
  let configure base =
    let open Sexplib.Sexp in
    List [Atom "lmdb";
          List [Atom "path"; Atom base];
          List [Atom "mode"; Atom "420"]]
    |> Rnt.Concepts.Configuration.term_of_sexp
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (LMDB_Configurator)

let suites () = [LMDB.suite "lmdb"]
