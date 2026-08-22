class type implementation = object
  method list : string list
  method find : string -> Handle.t option
end

type Handle.protocol += Directory of implementation

type t = implementation

let make impl = Directory impl

let from handle = Handle.into handle (function Directory impl -> Some impl | _ -> None)

let list i = Handle.invoke i (fun o -> o#list)

let find i name = Handle.invoke i (fun o -> o#find name)
