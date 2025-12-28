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
          # 1) Dette gir fileSystems."/" og fileSystems."/boot" osv
          ./hosts/hardware-configuration.nix

          # 2) Din host-konfig (tjenester, talos bootstrap, nettverk osv)
          ./hosts/nixos-host.nix

          # 3) Flake bygger ikke /etc/nixos/configuration.nix,
          #    så vi må sette bootloader + stateVersion her (eller i nixos-host.nix)
          ({ lib, ... }: {
            boot.loader.systemd-boot.enable = true;
            boot.loader.efi.canTouchEfiVariables = true;

            # Viktig: slå av grub selv om noe annet prøver å enable den
            boot.loader.grub.enable = lib.mkForce false;

            system.stateVersion = "25.11";
          })
        ];
      };

      apps.${system}.bootstrap = {
        type = "app";
        program = "${pkgs.bash}/bin/bash";
      };
    };
}
