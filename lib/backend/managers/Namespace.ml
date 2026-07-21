(* @composes Storage -- functor parameter *)
(* @needs Object *)
(* @needs Path *)
(* @needs Condition *)

module Make (Store : Abstract.Storage.STORAGE) = struct
  type tree = Object.rnt_object_tree

  let resolve (_txn : Store.transaction) (_tree : tree) (_path : Concepts.Path.t) :
      (Concepts.Path.t, Concepts.Condition.condition) result =
    failwith
      "NOT IMPLEMENTED: reparse loop with cycle guard; /system/branches/<n>/<sub> -> \
       /system/snapshots/<target_hash>/<sub> via Branch.target_hash"
end
