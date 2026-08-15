module Make (S : Abstract.Storage.STORAGE) = struct
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
