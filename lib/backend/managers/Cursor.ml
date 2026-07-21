(* @composes Storage -- functor parameter *)
(* @needs Path *)
(* @needs Tuple *)
(* @needs Value *)
(* @needs Condition *)

type descriptor =
  | Stored of {merkle_root: string}
  | Ephemeral of {merkle_root: string; dependencies: Concepts.Path.t BatFingerTree.t}

module Make (Store : Abstract.Storage.STORAGE) = struct
  type cursor = unit

  let open_ (_txn : Store.transaction) (descriptor : descriptor)
      ~(args : Concepts.Value.value BatFingerTree.t) : (cursor, Concepts.Condition.condition) result
      =
    ignore (descriptor, args);
    failwith "NOT IMPLEMENTED: open a cursor by paging the relation's Merkle tree over Store.get"

  let next (_cursor : cursor) : (Concepts.Tuple.t option, Concepts.Condition.condition) result =
    failwith "NOT IMPLEMENTED: page the next tuple over Store.get"

  let close (_cursor : cursor) : unit = ()
end
