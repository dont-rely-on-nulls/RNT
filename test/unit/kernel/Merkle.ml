open Rnt

module Make (S : Abstract.Storage.STORAGE) (C : Helpers.Storage.CONFIGURATOR) = struct
  open Alcotest

  module H = Helpers.Storage.Make (S) (C)
  module T = Rnt.Kernel.Merkle.Interface (S) (Rnt.Kernel.Merkle.StringKey) (Rnt.Kernel.Merkle.StringKey)

  (* TODO: be a bit more comprehensive (ideally, we want to test splits as well) *)
  let insert_and_lookup conn =
    let v1, v2, v3, v3', bogus =
      begin
        let open Utilities.Result in
        let* tx = S.start conn in
        let* node = T.empty
                    |> T.insert tx "k1" "v1"
                    |> fmap (T.insert tx "k2" "v2")
                    |> fmap (T.insert tx "k3" "v3")
        in
        let* node' = T.insert tx "k3" "toodles" node in
        let* v1 = T.lookup tx "k1" node in
        let* v2 = T.lookup tx "k2" node in
        let* v3 = T.lookup tx "k3" node in
        let* v3' = T.lookup tx "k3" node' in
        let* bogus = T.lookup tx "fnord" node in
        Ok (v1, v2, v3, v3', bogus)
      end
      |> Helpers.condition_as_failure
    in
    check (option string) "" (Some "v1") v1;
    check (option string) "" (Some "v2") v2;
    check (option string) "" (Some "v3") v3;
    check (option string) "" (Some "toodles") v3';
    check (option string) "" None bogus

  let persistence conn =
    let addr =
      begin
        let open Utilities.Result in
        let* tx = S.start conn in
        let* node = T.empty
                    |> T.insert tx "k1" "v1"
                    |> fmap (T.insert tx "k2" "v2")
                    |> fmap (T.insert tx "k3" "v3")
        in
        let* () = S.commit tx in
        Ok (T.hash_of node)
      end
      |> Helpers.condition_as_failure
    in
    let v1, v2, v3 =
      begin
        let open Utilities.Result in
        let* tx = S.start conn in
        let* node = T.find tx addr |> Result.map Option.get in
        let* v1 = T.lookup tx "k1" node in
        let* v2 = T.lookup tx "k2" node in
        let* v3 = T.lookup tx "k3" node in
        Ok (v1, v2, v3)
      end
      |> Helpers.condition_as_failure
    in
    check (option string) "" (Some "v1") v1;
    check (option string) "" (Some "v2") v2;
    check (option string) "" (Some "v3") v3

  (* TODO: this will need `remove` *)
  (* let determinism _conn = *)
  (*   () *)

  let suite prefix =
    ( "merkle/" ^ prefix,
      [test_case "insert-and-lookup" `Quick (H.with_connection insert_and_lookup "merkle-test");
       test_case "persistence" `Quick (H.with_connection persistence "merkle-test")])
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (Helpers.Storage.LMDB_Configurator)

let suites () = [LMDB.suite "lmdb"]
