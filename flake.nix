{
  description = "slskd-api: Python client for the slskd Soulseek daemon, used by LazyLibrarian.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pin = import ./pin.nix;
        inherit (pin) version hash;
        pkgs = import nixpkgs { inherit system; };
        slskd-api = pkgs.python3Packages.buildPythonPackage {
          pname = "slskd-api";
          inherit version;
          pyproject = true;
          # PyPI distribution name uses an underscore (`slskd_api`); Nix uses a dash by convention.
          src = pkgs.python3Packages.fetchPypi {
            pname = "slskd_api";
            inherit version hash;
          };
          build-system = with pkgs.python3Packages; [
            setuptools
            setuptools-git-versioning
          ];
          dependencies = [ pkgs.python3Packages.requests ];
          doCheck = false;
        };
        update-version = pkgs.writeShellApplication {
          name = "update-version";
          text = ''exec ${./update-version.sh} "$@"'';
        };
        update-branches = pkgs.writeShellApplication {
          name = "update-branches";
          text = ''exec ${./update-branches.sh} "$@"'';
        };
      in
      {
        packages = {
          inherit slskd-api update-version update-branches;
          default = slskd-api;
        };
      });
}
