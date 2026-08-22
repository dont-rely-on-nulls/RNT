let all_suites =
  Unit.Backend.Storage.suites ()

let () = Alcotest.run "RNT" all_suites
