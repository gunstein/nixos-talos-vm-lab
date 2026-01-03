{
  description = "NixOS host that bootstraps and provisions Talos on libvirt (profile-driven)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      nixosConfigurations.nixos-host = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./hosts/nixos-host.nix
        ];
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          bashInteractive
          git
          shellcheck
          shfmt
        ];
      };
    };
}