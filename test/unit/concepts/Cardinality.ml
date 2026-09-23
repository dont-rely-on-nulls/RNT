open Alcotest

module C = Rnt.Concepts.Cardinality

let klass = testable (fun ppf c -> Format.pp_print_string ppf (C.to_string c)) C.equal

let chain () =
  check bool "empty is least" true (C.leq C.Empty C.Countable);
  check bool "a tighter ceiling is smaller" true (C.leq (C.Bounded 2) (C.Bounded 5));
  check bool "a ceiling is finite" true (C.leq (C.Bounded 5) C.Finite);
  check bool "countable is greatest" true (C.leq C.Finite C.Countable);
  check bool "and nothing above it" false (C.leq C.Countable C.Finite)

let exhaustion () =
  check bool "a bounded generator can be exhausted" true (C.exhaustible (C.Bounded 3));
  check bool "a countable one cannot" false (C.exhaustible C.Countable)

let emptiness () = check klass "a ceiling of zero is emptiness" C.Empty (C.bounded 0)

let suites () =
  [ ( "concepts/cardinality",
      [ test_case "chain" `Quick chain;
        test_case "exhaustion" `Quick exhaustion;
        test_case "emptiness" `Quick emptiness ] ) ]
