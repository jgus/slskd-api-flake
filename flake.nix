{
  description = "slskd-api: Python client for the slskd Soulseek daemon, used by LazyLibrarian.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-lib = {
      url = "github:jgus/flake-lib/v1";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = { self, nixpkgs, flake-utils, flake-lib }:
    flake-lib.lib.mkLeafFlake {
      inherit nixpkgs flake-utils;
      # PyPI distribution name uses an underscore (`slskd_api`); Nix uses a dash by convention.
      source = { type = "pypi"; pname = "slskd_api"; format = "sdist"; };
      package = {
        attr = "slskd-api";
        description = "slskd-api: Python client for the slskd Soulseek daemon, used by LazyLibrarian.";
        buildSystem = ps: with ps; [ setuptools setuptools-git-versioning ];
        dependencies = ps: [ ps.requests ];
      };
      pin = import ./pin.nix;
    };
}
