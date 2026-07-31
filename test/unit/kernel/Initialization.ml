open Rnt

module Hash = Concepts.Hash
module Initialization = Rnt.Kernel.Initialization

module Memory_storage = struct
  type connection = (Hash.hash, Concepts.Representation.blob) Hashtbl.t
  type transaction = connection

  let connect _ = Ok (Hashtbl.create 16)
  let start conn = Ok conn
  let commit _ = Ok ()
  let abort _ = Ok ()
  let get tx address = Ok (Hashtbl.find_opt tx address)
  let put tx address blob = Hashtbl.replace tx address blob; Ok ()
end

module Store_initialization = Initialization.Make (Memory_storage)

let hash text = Hash.hash_of_bytes (Bytes.of_string text)

let address_to_blob address =
  Concepts.Object.Field.address address |> Concepts.Codec.Bencode.to_blob

let check_hash label expected actual =
  Alcotest.(check bool) label true (Hash.hash_equals expected actual)

let fail_condition c = Alcotest.fail (Concepts.Condition.to_string_hum c)

let test_initializes_branch_index_root () =
  let connection = Hashtbl.create 16 in
  let root =
    Store_initialization.initialize connection |> Helpers.condition_as_failure
  in
  Alcotest.(check bool)
    "fixed initialization key exists" true
    (Hashtbl.mem connection Initialization.fixed_label_address);
  Alcotest.(check bool) "branch index root exists" true (Hashtbl.mem connection root)

let test_initialization_reuses_existing_root () =
  let connection = Hashtbl.create 16 in
  let first =
    Store_initialization.initialize connection |> Helpers.condition_as_failure
  in
  let second =
    Store_initialization.initialize connection |> Helpers.condition_as_failure
  in
  check_hash "branch index root" first second

let test_read_reports_missing_branch_index () =
  let connection = Hashtbl.create 16 in
  let missing = hash "missing-branch-index" in
  Hashtbl.replace connection Initialization.fixed_label_address (address_to_blob missing);
  match Store_initialization.read connection with
  | Ok _ -> Alcotest.fail "expected missing branch index to fail"
  | Error c ->
      let message = Concepts.Condition.to_string_hum c in
      if not (String.starts_with ~prefix:"initialization-branch-index-missing" message)
      then fail_condition c

let suites () =
  [ ( "kernel/initialization",
      [ Alcotest.test_case "initializes branch index root" `Quick
          test_initializes_branch_index_root;
        Alcotest.test_case "reuses existing branch index root" `Quick
          test_initialization_reuses_existing_root;
        Alcotest.test_case "reports missing branch index" `Quick
          test_read_reports_missing_branch_index ] ) ]
