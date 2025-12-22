{
  description = "NixOS host that bootstraps Talos on libvirt (profile-driven)";

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

      # Valgfritt: en "app" for å kjøre bootstrap manuelt med nix run
      # (men du trenger ikke dette når du har systemd-service)
      apps.${system}.bootstrap = {
        type = "app";
        program = "${pkgs.bash}/bin/bash";
        # usage: nix run .#bootstrap -- lab1
      };
    };
}
