{
  description = "RNT — Relations, Not Tables: an experimental database kernel (OCaml library)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f (import nixpkgs { inherit system; }));
    in
    {
      packages = forAllSystems (pkgs:
        let ocamlPackages = pkgs.ocamlPackages; in
        {
          default = ocamlPackages.buildDunePackage {
            pname = "rnt";
            version = "0.1.0";
            duneVersion = "3";
            src = self;

            propagatedBuildInputs = [ ocamlPackages.batteries ];
            checkInputs = [ ocamlPackages.alcotest ];
            doCheck = true;

            meta = {
              description =
                "RNT database kernel inspired by the Windows NT object manager";
              license = pkgs.lib.licenses.agpl3Only;
              maintainers = [ { name = "Marcos Magueta"; } ];
            };
          };
        });

      devShells = forAllSystems (pkgs:
        let ocamlPackages = pkgs.ocamlPackages; in
        {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${pkgs.system}.default ];
            packages = [
              pkgs.dune_3
              ocamlPackages.ocaml
              ocamlPackages.ocaml-lsp
              ocamlPackages.ocamlformat
              ocamlPackages.utop
              ocamlPackages.batteries
              ocamlPackages.alcotest
              ocamlPackages.ctypes
              ocamlPackages.ctypes-foreign
            ];
          };
        });
    };
}
