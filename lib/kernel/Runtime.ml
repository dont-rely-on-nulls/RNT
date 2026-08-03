module Error = struct
  open Concepts.Condition

  let registry_conflict () =
    condition "registry-object-update-conflict" "Failed to update the in-memory object registry"
      empty
end

module CAS : Backend.Managers.Object.RUNTIME_STRATEGY = struct
  type 'a state = 'a Atomic.t
  type 'a token = 'a

  let create = Atomic.make

  let acquire state =
    let photograph = Atomic.get state in
    photograph, photograph

  let publish state token next =
    if Atomic.compare_and_set state token next then Ok () else Error (Error.registry_conflict ())
end

(* module MVCC : REGISTRY_STRATEGY = struct end *)
(* module RCU : REGISTRY_STRATEGY = struct end *)

module Make (Strategy : Backend.Managers.Object.RUNTIME_STRATEGY) (Store : Abstract.Storage.STORAGE) =
struct
  module Init = Initialization.Make (Store)
  module Objects = Backend.Managers.Object.Make (Strategy)

  type t = {connection: Store.connection; objects: Objects.t}

  let initialize configuration : (t, Concepts.Condition.condition) result =
    let open Utilities.Result in
    let* connection = Store.connect configuration in
    let* branch_index_root = Init.initialize connection in
    (* Registry reconstruction from the branch index is the loader boundary.
       Until that loader exists, publish only the permanent /system namespace;
       importantly, the discovered root remains part of the photograph. *)
    let objects = Objects.create ~branch_index_root ~registry:Backend.Managers.Object.root in
    Ok {connection; objects}

  let connection runtime = runtime.connection
  let objects runtime = runtime.objects
end
