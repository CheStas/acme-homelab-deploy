{
  description = "acme-homelab-deploy dev shell (dev machine only; the Pi has no nix)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (sys: f sys);
    in {
      devShells = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in
        {
          default = pkgs.mkShell {
            # bash 5+ is needed for the `coproc` used by lib/jsonrpc.sh;
            # the system bash on macOS is 3.2.
            packages = with pkgs; [ bash coreutils websocat jq bats shellcheck shfmt ];
          };
        });
    };
}