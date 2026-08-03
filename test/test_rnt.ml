let all_suites =
  Unit.Concepts.Serialization.suites ()
  @ Unit.Backend.Storage.suites ()
  @ Unit.Backend.Lifecycle.suites ()
  @ Unit.Kernel.Merkle.suites ()

let () = Alcotest.run "RNT" all_suites
