module Make (S : Abstract.Storage.STORAGE) = struct
  module Pointer = struct
    type 'a t = {
      addr : S.address;
      loader : S.transaction -> S.address -> ('a, Concepts.Condition.condition) result
    }

    let make addr loader = { addr; loader }
    let address_of { addr; _ } = addr
    let swap { loader; _ } addr = make addr loader
    let deref tx { addr; loader } = loader tx addr
  end

  let finish tx = function
    | Ok value ->
       let open Utilities.Result in
       let* () = S.commit tx in
       Ok value
    | Error condition ->
       let _ = S.abort tx in
       Error condition

  let with_transaction connection body =
    let open Utilities.Result in
    let* tx = S.start connection in
    body tx |> finish tx

  let store_blob tx blob =
    let open Utilities.Result in
    let address = Concepts.Hash.hash_of_blob blob in
    let* () = S.put tx (S.Hash address) blob in
    Ok address

end
