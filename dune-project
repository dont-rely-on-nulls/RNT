(lang dune 3.6)

(name rnt)

(generate_opam_files true)

(source
 (github dont-rely-on-nulls/RNT))

(license AGPL-3.0-only)

(authors "Marcos Magueta" "Estevan Castilho")

(maintainers "Marcos Magueta <maguetamarcos@gmail.com>")

(package
 (name rnt)
 (synopsis "Relations, Not Tables: an experimental database kernel")
 (description
  "RNT is an experimental database kernel inspired by the object-management model of the Windows NT kernel.")
 (depends
  (ocaml
   (>= 4.14))
  batteries
  (alcotest :with-test)))
