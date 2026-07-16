let permits (object_ : Object.registry) (method_ : Object.rnt_method) : bool =
  BatSet.mem method_ object_.Object.entry.Object.methods

let can_open (object_ : Object.registry) : bool = permits object_ Object.OPEN
let can_close (object_ : Object.registry) : bool = permits object_ Object.CLOSE
