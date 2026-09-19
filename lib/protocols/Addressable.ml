class type implementation = object
  method address : Concepts.Hash.hash
end

type Handle.protocol += Addressable of implementation

type t = implementation

let make impl = Addressable (impl :> implementation)

let from handle = Handle.into handle (function Addressable impl -> Some impl | _ -> None)

let address i = Handle.invoke i (fun o -> o#address)
