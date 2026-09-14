{
  description = "Oh My Pi coding agent built from source for Nix";

  inputs = {
    nixpkgs = {
      url = "github:NixOS/nixpkgs/nixos-unstable";
    };
    source = {
      url = "github:can1357/oh-my-pi/main";
      flake = false;
    };
    bun2nix = {
      url = "github:nix-community/bun2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-bun = {
      url = "github:ryoppippi/nix-bun";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      bun2nix,
      nix-bun,
      nixpkgs,
      rust-overlay,
      source,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor = system: nixpkgs.legacyPackages.${system};
      bun2nixFor = system: bun2nix.packages.${system}.bun2nix;
      rustToolchainFor =
        system:
        (rust-overlay.lib.mkRustBin { } (pkgsFor system)).fromRustupToolchainFile
          "${source}/rust-toolchain.toml";

      packageFor =
        system:
        let
          pkgs = pkgsFor system;
          bun = pkgs.callPackage (nix-bun.outPath + "/package.nix") {
            sourcesFile = nix-bun.outPath + "/versions/1.4.2.json";
          };
        in
        pkgs.callPackage ./packages/omp.nix {
          inherit source bun;
          bun2nix = bun2nixFor system;
          rustToolchain = rustToolchainFor system;
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          omp = packageFor system;
        in
        {
          inherit omp;
          default = omp;
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/omp";
          meta.description = "Run OMP";
        };
      });

      checks = forAllSystems (system: {
        omp = self.packages.${system}.omp;
      });

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);

      nixosModules.default = import ./modules/nixos.nix { inherit self; };
      homeManagerModules.default = import ./modules/home-manager.nix { inherit self; };

      overlays.default = _final: previous: {
        omp = self.packages.${previous.stdenv.hostPlatform.system}.omp;
      };
    };
}
