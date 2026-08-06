open Rnt

module StringKey : Rnt.Kernel.Merkle.KEY with type t = string = struct
  type t = string

  let encode s = String.to_bytes s |> Concepts.Representation.blob_of_bytes
  let compare s1 s2 = String.compare s1 s2 |> Concepts.Ordering.of_int
  let decode b = Concepts.Representation.bytes_of_blob b |> String.of_bytes |> Result.ok
end

module Make (S : Abstract.Storage.STORAGE) (C : Helpers.Storage.CONFIGURATOR) = struct
  open Alcotest

  module H = Helpers.Storage.Make (S) (C)
  module T = Rnt.Kernel.Merkle.Interface (S) (StringKey) (StringKey)

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
        let* () = S.abort tx in
        Ok (v1, v2, v3, v3', bogus)
      end
      |> Helpers.condition_as_failure
    in
    check (option string) "that in-memory reads from the first write work properly" (Some "v1") v1;
    check (option string) "that in-memory reads from the second write work properly" (Some "v2") v2;
    check (option string) "that in-memory reads from the third write work properly" (Some "v3") v3;
    check (option string) "that in-memory reads from a value replacement work properly" (Some "toodles") v3';
    check (option string) "that in-memory reads from a non-existent key returns nothing" None bogus

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
    check (option string) "that on-disk reads from the first write work properly" (Some "v1") v1;
    check (option string) "that on-disk reads from the second write work properly" (Some "v2") v2;
    check (option string) "that on-disk reads from the third write work properly" (Some "v3") v3

  let iteration conn =
    let keys, values =
      begin
        let open Utilities.Result in
        let* tx = S.start conn in
        let* node = T.empty
                    |> T.insert tx "k1" "v1"
                    |> fmap (T.insert tx "k2" "v2")
                    |> fmap (T.insert tx "k3" "v3")
        in
        let* keys = T.fold_left tx (fun acc k _ -> k :: acc) [] node in
        let* values = T.fold_left tx (fun acc _ v -> v :: acc) [] node in
        let* () = S.abort tx in
        Ok (keys, values)
      end
      |> Helpers.condition_as_failure
    in
    check (list string) "that keys are properly enumerated from left to right" ["k1"; "k2"; "k3"] keys;
    check (list string) "that values are properly enumerated from left to right" ["v1"; "v2"; "v3"] values

  (* TODO: this will need `remove` *)
  (* let determinism _conn = *)
  (*   () *)

  let suite prefix =
    ( "merkle/" ^ prefix,
      [test_case "insert-and-lookup" `Quick (H.with_connection insert_and_lookup "merkle-test");
       test_case "persistence" `Quick (H.with_connection persistence "merkle-test");
       test_case "iteration" `Quick (H.with_connection persistence "merkle-test")])
end

module LMDB = Make (Rnt.Backend.Storage.LMDB) (Helpers.Storage.LMDB_Configurator)

let suites () = [LMDB.suite "lmdb"]
