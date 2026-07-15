open Rnt

module type CONFIGURATOR = sig
  val configure : string -> Rnt.Concepts.Configuration.term
end

module Make (S : Abstract.Storage.STORAGE) (C : CONFIGURATOR) = struct
  open Alcotest

  let with_connection f () =
    Helpers.with_temporary_directory "storage-test" begin fun dir ->
        begin
          let open Utilities.Result in
          let* conn = S.connect (C.configure dir) in
          Ok (f conn)
        end
        |> Helpers.condition_as_failure
      end

  let storage_and_retrieval conn =
    let key = Concepts.Hash.hash_of_value (Concepts.Value.String "value") in
    let value = Concepts.Value.Integer 42 in
    let blob = Concepts.Representation.blob_of_value value in
    let v, v' =
      begin
        let open Utilities.Result in
        let* tx = S.start conn in
        let* v = S.get tx key in
        let* () = S.put tx key blob in
        let* v' = S.get tx key in
        Ok Concepts.Representation.(Option.map value_of_blob v, Option.map value_of_blob v')
      end
      |> Helpers.condition_as_failure
    in
    check (option Helpers.value) "`get` before `put` should return no value" None v;
    check (option Helpers.value) "`get` after `put` should return the inserted value" (Some value)
      v'

  let suite prefix =
    ( "storage/" ^ prefix,
      [test_case "storage-and-retrieval" `Quick (with_connection storage_and_retrieval)] )
end

module LMDB_Configurator : CONFIGURATOR = struct
  let configure base =
    let open Sexplib.Sexp in
    List [Atom "lmdb"; List [Atom "path"; Atom base]; List [Atom "mode"; Atom "420"]]
    |> Rnt.Concepts.Configuration.term_of_sexp
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (LMDB_Configurator)

let suites () = [LMDB.suite "lmdb"]
