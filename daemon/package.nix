{
  lib,
  rustPlatform,
  git,
}:

rustPlatform.buildRustPackage {
  pname = "diffreel-daemon";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ./.;
    filter = path: _: builtins.baseNameOf path != "target";
  };
  cargoLock.lockFile = ./Cargo.lock;
  nativeCheckInputs = [ git ];

  meta = {
    description = "Repository state and blob service for diffreel.nvim";
    mainProgram = "diffreel-daemon";
    platforms = lib.platforms.darwin;
  };
}
