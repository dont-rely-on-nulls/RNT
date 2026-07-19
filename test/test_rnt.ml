let all_suites = Unit.Backend.Storage.suites () @ Unit.Backend.Lifecycle.suites ()
let () = Alcotest.run "RNT" all_suites
