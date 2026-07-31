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

let fail_condition c = Alcotest.fail (Concepts.Condition.to_string_hum c)
let hash text = Hash.hash_of_bytes (Bytes.of_string text)

let check_hash label expected actual =
  Alcotest.(check bool) label true (Hash.hash_equals expected actual)

let test_initialization_round_trips () =
  let expected =
    Initialization.make ~default_branch:"master" ~branches:(hash "branch-index")
  in
  match Initialization.(expected |> to_bytes |> of_bytes) with
  | Ok actual ->
      Alcotest.(check string)
        "default branch"
        (Initialization.default_branch expected)
        (Initialization.default_branch actual);
      check_hash "branches" (Initialization.branches expected) (Initialization.branches actual)
  | Error c -> fail_condition c

let test_registers_under_fixed_label () =
  let tx = Hashtbl.create 16 in
  let expected =
    Initialization.make ~default_branch:"master" ~branches:(hash "branch-index")
  in
  let before, registered, after =
    begin
      let open Utilities.Result in
      let* before = Store_initialization.load tx in
      let* registered = Store_initialization.register tx expected in
      let* after = Store_initialization.load tx in
      Ok (before, registered, after)
    end
    |> Helpers.condition_as_failure
  in
  Alcotest.(check (option bool))
    "missing before registration" None (Option.map (Fun.const true) before);
  check_hash "registered address" (Initialization.address expected) registered;
  Alcotest.(check bool)
    "fixed label exists" true
    (Hashtbl.mem tx Initialization.fixed_label_address);
  match after with
  | Some actual -> Alcotest.(check bool) "loaded object" true (Initialization.equal expected actual)
  | None -> Alcotest.fail "expected initialization object after registration"

let suites () =
  [ ( "kernel/initialization",
      [ Alcotest.test_case "initialization round-trips" `Quick
          test_initialization_round_trips;
        Alcotest.test_case "registers under fixed label" `Quick
          test_registers_under_fixed_label ] ) ]
