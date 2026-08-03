let all_suites =
  Unit.Concepts.Serialization.suites ()
  @ Unit.Backend.Storage.suites ()
  @ Unit.Backend.Lifecycle.suites ()
  @ [Unit.Backend.ObjectManager.suite]
  @ Unit.Kernel.Merkle.suites ()
  @ [Unit.Kernel.Runtime.suite]

let () = Alcotest.run "RNT" all_suites
