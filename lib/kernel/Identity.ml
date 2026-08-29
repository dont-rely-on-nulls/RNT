class type identity = object
  method hash : Concepts.Hash.hash
end

class of_id = object (self)
  method hash = Oo.id self |> Concepts.Hash.hash_of_int
end
