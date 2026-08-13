module BranchValue = Merkle.StringKey (* FIXME *)

type branch = string

module Make (S : Abstract.Storage.STORAGE) = struct
  module I = Merkle.Interface (S) (Merkle.StringKey) (BranchValue)
  module SI = Storage.Make (S)

  type manager = { storage: S.connection; head: I.node Atomic.t }

  let initialize storage addr =
    let open Utilities.Result in
    SI.with_transaction storage (fun tx ->
        let* head = I.find tx addr in
        Ok { storage; head = Option.value head ~default:I.empty |> Atomic.make })

  let fetch { storage; head } branch_name =
    SI.with_transaction storage (fun tx ->
        let head = Atomic.get head in
        I.lookup tx branch_name head)

  let update ({ storage; head } as manager) branch_name f =
    let open Utilities.Result in
    SI.with_transaction storage (fun tx ->
        let* new_head = Utilities.Atomic.mswap head (fun head ->
                            let* branch = I.lookup tx branch_name head in
                            f branch) in
        Ok { manager with head = new_head })
end
