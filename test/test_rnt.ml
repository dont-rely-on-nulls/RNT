let test_version () = Alcotest.(check string) "version" "0.1.0" Rnt.version
let () = Alcotest.run "rnt" ["smoke", [Alcotest.test_case "version" `Quick test_version]]
