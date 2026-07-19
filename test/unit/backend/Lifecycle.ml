module Object = Rnt.Backend.Managers.Object
module Lifecycle = Rnt.Backend.Managers.Lifecycle
module Path = Rnt.Concepts.Path

(* Small builders so the tests read like the invariants they check. *)

let path segments = Path.of_list segments
let relation name = Object.make_object (Object.Relation {merkle_root= name})

let session () =
  Object.make_object (Object.Session {connection_context= (); branch_overrides= BatMap.String.empty})

let branch name = Object.make_object (Object.Branch {name; target_hash= "hash"})
let namespace label = Object.make_object (Object.Namespace {label; predicate= (fun _ -> true)})
let dependencies paths = List.fold_left BatFingerTree.snoc BatFingerTree.empty paths

let ephemeral name deps =
  Object.make_object (Object.EphemeralRelation {merkle_root= name; dependencies= dependencies deps})

let register_exn tree p object' = Helpers.condition_as_failure (Object.register p object' tree)
let unregister_exn tree p = Helpers.condition_as_failure (Object.unregister p tree)
let collect_exn tree p = Helpers.condition_as_failure (Lifecycle.collect tree p)

let reference_count tree p =
  match Object.find p tree with Some r -> r.Object.reference_count | None -> -1

let present tree p = Object.find p tree <> None

(* An ephemeral relation holds its inputs resident. Registering it raises the
   input's reference_count; unregistering it lowers it again. This is the
   distinction between reference counting (real edges) and pinning. *)
let test_edges_track_dependents () =
  let tree = register_exn Object.root (path ["r1"]) (relation "r1") in
  let tree = register_exn tree (path ["er1"]) (ephemeral "er1" [path ["r1"]]) in
  Alcotest.(check int)
    "dependent raises the input's reference count" 1
    (reference_count tree (path ["r1"]));
  let tree = unregister_exn tree (path ["er1"]) in
  Alcotest.(check int)
    "removing the dependent releases the input" 0
    (reference_count tree (path ["r1"]))

(* The four gates of eligibility, each shown to block on its own. *)
let test_eligibility_gates () =
  let tree = register_exn Object.root (path ["r1"]) (relation "r1") in
  Alcotest.(check bool)
    "a fresh durable object is collectable" true
    (Lifecycle.is_eligible_for_gc tree (path ["r1"]));
  Alcotest.(check bool)
    "an open handle blocks collection" false
    (Lifecycle.is_eligible_for_gc (Lifecycle.monitor tree (path ["r1"])) (path ["r1"]));
  Alcotest.(check bool)
    "a pin blocks collection" false
    (Lifecycle.is_eligible_for_gc (Lifecycle.pin tree (path ["r1"])) (path ["r1"]));
  let with_branch = register_exn Object.root (path ["b1"]) (branch "b1") in
  Alcotest.(check bool)
    "a branch is exempt even with zero counts" false
    (Lifecycle.is_eligible_for_gc with_branch (path ["b1"]))

(* Collecting a dependent cascades into the inputs it releases, and the input
   cannot be collected first while the dependent is alive. *)
let test_cascade_follows_edges () =
  let tree = register_exn Object.root (path ["r1"]) (relation "r1") in
  let tree = register_exn tree (path ["er1"]) (ephemeral "er1" [path ["r1"]]) in
  Alcotest.(check bool)
    "a live dependent keeps its input" false
    (Lifecycle.is_eligible_for_gc tree (path ["r1"]));
  let tree, disposals = collect_exn tree (path ["er1"]) in
  Alcotest.(check bool) "the dependent is collected" false (present tree (path ["er1"]));
  Alcotest.(check bool) "the released input is cascaded out" false (present tree (path ["r1"]));
  Alcotest.(check int) "durable collection needs no disposal" 0 (List.length disposals)

(* A pin overrides the cascade: the input stays even after its dependent goes. *)
let test_pin_survives_cascade () =
  let tree = register_exn Object.root (path ["r1"]) (relation "r1") in
  let tree = register_exn tree (path ["er1"]) (ephemeral "er1" [path ["r1"]]) in
  let tree = Lifecycle.pin tree (path ["r1"]) in
  let tree, _ = collect_exn tree (path ["er1"]) in
  Alcotest.(check bool) "the dependent is still collected" false (present tree (path ["er1"]));
  Alcotest.(check bool) "the pinned input survives" true (present tree (path ["r1"]))

(* Collecting a runtime object surfaces a disposal for the caller to run,
   because there is no durable form to rehydrate from. *)
let test_runtime_collection_surfaces_disposal () =
  let tree = register_exn Object.root (path ["s1"]) (session ()) in
  let tree, disposals = collect_exn tree (path ["s1"]) in
  Alcotest.(check bool) "the session is removed" false (present tree (path ["s1"]));
  match disposals with
  | [{Lifecycle.kind= Object.Session _; _}] -> ()
  | _ -> Alcotest.fail "expected exactly one session disposal"

(* A namespace with objects under it is scaffolding, so it is kept rather than
   collected, and this is not an error. *)
let test_populated_namespace_is_kept () =
  let tree = register_exn Object.root (path ["ns"]) (namespace "ns") in
  let tree = register_exn tree (path ["ns"; "r1"]) (relation "r1") in
  let tree, _ = collect_exn tree (path ["ns"]) in
  Alcotest.(check bool) "a populated namespace is kept" true (present tree (path ["ns"]))

(* Property: pinning is a decision, reference counting is bookkeeping. No
   sequence of pin/unpin may ever move the reference count. *)
let prop_pin_never_moves_reference_count =
  QCheck.Test.make ~name:"pin/unpin never changes reference_count" ~count:200
    QCheck.(list bool)
    (fun operations ->
      let tree = register_exn Object.root (path ["r1"]) (relation "r1") in
      let tree =
        List.fold_left
          (fun tree pin ->
            if pin then Lifecycle.pin tree (path ["r1"]) else Lifecycle.unpin tree (path ["r1"]) )
          tree operations
      in
      reference_count tree (path ["r1"]) = 0 )

(* Property: reference edges are balanced. Registering an ephemeral relation
   over any selection of inputs and then unregistering it returns every input
   to its baseline count, whatever the selection or its duplicates. *)
let prop_edges_are_balanced =
  QCheck.Test.make ~name:"register then unregister an ER restores input counts" ~count:200
    QCheck.(pair (int_range 1 5) (list (int_range 0 4)))
    (fun (input_count, selection) ->
      let inputs = List.init input_count (fun i -> path [Printf.sprintf "r%d" i]) in
      let tree =
        List.fold_left
          (fun tree p -> register_exn tree p (relation (Path.to_string p)))
          Object.root inputs
      in
      let chosen =
        List.filter (fun i -> i < input_count) selection
        |> List.map (fun i -> path [Printf.sprintf "r%d" i])
      in
      let tree = register_exn tree (path ["er"]) (ephemeral "er" chosen) in
      let tree = unregister_exn tree (path ["er"]) in
      List.for_all (fun p -> reference_count tree p = 0) inputs )

let suites () =
  [ ( "lifecycle/registry",
      [ Alcotest.test_case "edges track dependents" `Quick test_edges_track_dependents;
        Alcotest.test_case "eligibility gates" `Quick test_eligibility_gates;
        Alcotest.test_case "cascade follows edges" `Quick test_cascade_follows_edges;
        Alcotest.test_case "pin survives cascade" `Quick test_pin_survives_cascade;
        Alcotest.test_case "runtime collection surfaces disposal" `Quick
          test_runtime_collection_surfaces_disposal;
        Alcotest.test_case "populated namespace is kept" `Quick test_populated_namespace_is_kept ] );
    ( "lifecycle/properties",
      List.map QCheck_alcotest.to_alcotest
        [prop_pin_never_moves_reference_count; prop_edges_are_balanced] ) ]
