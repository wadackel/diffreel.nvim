{
  description = "Git worktree diff viewer for Neovim";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      rustVersion =
        (builtins.fromTOML (builtins.readFile ./daemon/rust-toolchain.toml)).toolchain.channel;
      denoVersion = nixpkgs.lib.trim (builtins.readFile ./.deno-version);
      distribution = builtins.fromJSON (builtins.readFile ./distribution.json);
      pkgsFor =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        assert nixpkgs.lib.assertMsg (distribution.rust == rustVersion)
          "distribution.json pins Rust ${distribution.rust}, but daemon/rust-toolchain.toml pins ${rustVersion}";
        assert nixpkgs.lib.assertMsg
          (builtins.all (tool: tool.version == rustVersion) [
            pkgs.rustc
            pkgs.cargo
            pkgs.rustfmt
            pkgs.clippy
          ])
          "Expected Rust tools ${rustVersion}; nixpkgs provides rustc ${pkgs.rustc.version}, cargo ${pkgs.cargo.version}, rustfmt ${pkgs.rustfmt.version}, clippy ${pkgs.clippy.version}";
        assert nixpkgs.lib.assertMsg (
          pkgs.deno.version == denoVersion
        ) ".deno-version pins Deno ${denoVersion}, but nixpkgs provides ${pkgs.deno.version}";
        pkgs;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          checkPackages = with pkgs; [
            cargo
            rustc
            rustfmt
            deno
            stylua
            just
            nixfmt
          ];
        in
        {
          default = pkgs.mkShell {
            packages =
              checkPackages
              ++ (with pkgs; [
                clippy
                neovim
                git
              ]);
          };
          ci = pkgs.mkShellNoCC {
            packages = checkPackages;
          };
        }
      );
      packages.aarch64-darwin.default = (pkgsFor "aarch64-darwin").callPackage ./daemon/package.nix { };
      checks.aarch64-darwin.daemon = self.packages.aarch64-darwin.default;
      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
