module type REGISTRY_STRATEGY = sig
  type 'a state
  (* The exact snapshot observed on acquire *)
  type 'a token

  val create : 'a -> 'a state
  val acquire : 'a state -> 'a * 'a token
  val publish : 'a state -> 'a token -> 'a -> (unit, Concepts.Condition.condition) result
end

module Error = struct
  open Concepts.Condition
  let registry_conflict () =
    let msg = "Failed to update the in-memory object registry." in
    condition "registry-object-update-conflict" msg empty
end

module CAS : REGISTRY_STRATEGY = struct
  type 'a state = 'a Atomic.t
  type 'a token = 'a
  let create = Atomic.make
  let acquire state =
    let photograph = Atomic.get state in
    (* Just the same here because of CAS. On MVCC this would be a version number*)
    photograph, photograph
  let publish state token next =
    if Atomic.compare_and_set state token next then Ok ()
  else Error (Error.registry_conflict ())
end

(* module MVCC : REGISTRY_STRATEGY = struct end *)
(* module RCU : REGISTRY_STRATEGY = struct end *)

module Make (Strategy : REGISTRY_STRATEGY) (Store: Abstract.Storage.STORAGE) = struct
  module Init = Initialization.Make(Store)

  type photograph =
    { branch_index_root: Concepts.Hash.hash
    ; registry : Backend.Managers.Object.rnt_object_tree }

  type t =
    { connection : Store.connection
    ; state : photograph Strategy.state }
  
  let initialize configuration : (t, Concepts.Condition.condition) result =
    let open Utilities.Result in
    let* connection = Store.connect configuration in
    let* branch_index_root = Init.initialize connection in
    
end
