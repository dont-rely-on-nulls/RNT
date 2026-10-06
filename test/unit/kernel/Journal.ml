open Rnt
open Alcotest
module J = Protocols.Journal

let ok = Helpers.condition_as_failure
let thing () = Rnt.Kernel.Prototype.mixture []

let journal () =
  let handle = Rnt.Kernel.Journal.make ~bindings:["A", thing ()] () in
  handle, ok (J.require handle)

let bound directory name =
  let listing = ok (Protocols.Handle.require Protocols.Directory.from directory) in
  ok (Protocols.Directory.find listing name) |> Option.is_some

let a_registry_update_is_a_commit () =
  let handle, journal = journal () in
  let registry = Protocols.Registry.from handle |> Option.get in
  check bool "bound" true (ok (Protocols.Registry.update registry "B" None (Some (thing ()))));
  let history = J.history journal in
  check (list int) "numbered" [0; 1] (List.map (fun (c : J.commit) -> c.number) history);
  check bool "the first snapshot keeps its past" false (bound (List.hd history).snapshot "B");
  check bool "the head sees it" true (bound (J.head journal).snapshot "B")

let a_commit_binds_together_or_not_at_all () =
  let _, journal = journal () in
  let changes stale =
    J.
      [ {name= "B"; expected= None; replacement= Some (thing ())};
        { name= "C";
          expected= (if stale then Some (thing ()) else None);
          replacement= Some (thing ()) } ]
  in
  check bool "a stale expectation" true (ok (J.commit journal (changes true)) = None);
  check int "nothing landed" 0 (J.head journal).number;
  let commit = ok (J.commit journal (changes false)) |> Option.get in
  check (list string) "both" ["B"; "C"] commit.changed;
  check bool "B" true (bound commit.snapshot "B");
  check bool "C" true (bound commit.snapshot "C")

let a_guard_refuses_and_an_observer_hears () =
  let _, journal = journal () in
  let heard = ref [] in
  J.observe journal "ear" (Some (fun c -> heard := c.number :: !heard));
  J.guard journal "no-B"
    (Some
       (fun {proposed; _} ->
         if List.mem "B" proposed.changed then
           Error Concepts.Condition.(condition "no-B" "B stays unbound" empty)
         else Ok () ) );
  let change name = [J.{name; expected= None; replacement= Some (thing ())}] in
  check bool "refused" true (Result.is_error (J.commit journal (change "B")));
  check bool "allowed" true (Result.is_ok (J.commit journal (change "C")));
  check (list int) "heard only what landed" [1] !heard

let a_snapshot_hands_out_derived_relations_against_itself () =
  let derived =
    Rnt.Kernel.Prototype.mixture
      [ Protocols.Derived.make
          object
            method within directory =
              Ok
                (Rnt.Kernel.Prototype.mixture
                   [Rnt.Kernel.Prototype.Directory.of_properties ["seen", directory]] )
          end ]
  in
  let snapshot = Rnt.Kernel.Journal.snapshot ["D", derived] in
  let read = ok (Rnt.Kernel.Path.lookup snapshot Rnt.Kernel.Path.("D" @/ "seen" @/ this)) in
  check bool "read against the snapshot" true (Protocols.Handle.equal read snapshot)

let suites () =
  [ ( "kernel/journal",
      [ test_case "a registry update is a commit" `Quick a_registry_update_is_a_commit;
        test_case "a commit binds together or not at all" `Quick
          a_commit_binds_together_or_not_at_all;
        test_case "a guard refuses and an observer hears" `Quick
          a_guard_refuses_and_an_observer_hears;
        test_case "a snapshot hands out derived relations against itself" `Quick
          a_snapshot_hands_out_derived_relations_against_itself ] ) ]

let schema = BatMap.String.singleton "N" {Protocols.Schematics.domain= "integer"; provenance= []}

let row n =
  {Concepts.Tuple.type_= "R"; attributes= BatMap.String.singleton "N" (Concepts.Value.Integer n)}

let count relation =
  let _, tuples = ok (Rnt.Kernel.View.read relation) in
  List.length tuples

let rebinding_lands_as_one_commit_or_one_name_at_a_time () =
  let handle, journal = journal () in
  let fixed n = Rnt.Kernel.View.fixed schema (List.init n row) in
  ok (Rnt.Kernel.Journal.rebind handle ["A", Some (fixed 1); "B", Some (fixed 2)]);
  ok (Rnt.Kernel.Journal.rebind handle ["A", Some (fixed 3)]);
  check (list int) "two commits after the first" [0; 1; 2]
    (List.map (fun (c : J.commit) -> c.number) (J.history journal));
  let plain = Rnt.Kernel.Namespace.make () in
  ok (Rnt.Kernel.Journal.rebind plain ["A", Some (fixed 1)]);
  ok (Rnt.Kernel.Journal.rebind plain ["A", Some (fixed 4)]);
  check int "a plain namespace too" 4
    (count (ok (Rnt.Kernel.Path.lookup plain Rnt.Kernel.Path.("A" @/ this))))

(* A computed relation counts the tuples of A in whatever it is read
   against, so the first snapshot still sees one and the head three. *)
let a_computed_relation_reads_as_of_its_snapshot () =
  let ( let* ) = Result.bind in
  let handle, journal = journal () in
  let fixed n = Rnt.Kernel.View.fixed schema (List.init n row) in
  let counting =
    Rnt.Kernel.View.computed schema
      ~current:(fun () -> Ok handle)
      (fun directory ->
        let* a = Rnt.Kernel.Path.lookup directory Rnt.Kernel.Path.("A" @/ this) in
        Ok [row (count a)] )
  in
  ok (Rnt.Kernel.Journal.rebind handle ["A", Some (fixed 1); "C", Some counting]);
  ok (Rnt.Kernel.Journal.rebind handle ["A", Some (fixed 3)]);
  let read snapshot =
    let c = ok (Rnt.Kernel.Path.lookup snapshot Rnt.Kernel.Path.("C" @/ this)) in
    let _, tuples = ok (Rnt.Kernel.View.read c) in
    BatMap.String.find "N" (List.hd tuples).Concepts.Tuple.attributes
  in
  let history = J.history journal in
  check Helpers.value "as it was" (Concepts.Value.Integer 1) (read (List.nth history 1).snapshot);
  check Helpers.value "as it is" (Concepts.Value.Integer 3) (read (J.head journal).snapshot)

let suites () =
  suites ()
  @ [ ( "kernel/view",
        [ test_case "rebinding lands as one commit, or one name at a time" `Quick
            rebinding_lands_as_one_commit_or_one_name_at_a_time;
          test_case "a computed relation reads as of its snapshot" `Quick
            a_computed_relation_reads_as_of_its_snapshot ] ) ]
