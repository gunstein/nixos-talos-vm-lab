# =====================================================================
# FILE: hosts/nixos-host.nix
# =====================================================================
{ config, lib, pkgs, ... }:

let
  passFile = "/etc/nixos/secrets/gunstein.passwd";
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking.hostName = "nixos";
  networking.networkmanager.enable = true;

  services.openssh.enable = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  users.mutableUsers = true;

  users.users.gunstein = {
    isNormalUser = true;
    extraGroups = [ "wheel" "libvirtd" ];
    initialHashedPassword =
      lib.mkIf (builtins.pathExists passFile) (builtins.readFile passFile);
  };

  environment.systemPackages = with pkgs; [
    bash coreutils gnugrep gawk util-linux
    iproute2 iputils netcat-openbsd
    git vim

    libvirt qemu_kvm qemu virt-manager virt-viewer

    talosctl kubectl
  ];

  virtualisation.libvirtd.enable = true;
  virtualisation.libvirtd.onBoot = "start";
  virtualisation.libvirtd.onShutdown = "shutdown";

  system.stateVersion = "24.11";
}
