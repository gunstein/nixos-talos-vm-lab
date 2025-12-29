{
  description = "NixOS host that bootstraps and provisions Talos on libvirt (profile-driven)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: {
    nixosConfigurations.nixos-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/nixos-host.nix
      ];
    };
  };
}
