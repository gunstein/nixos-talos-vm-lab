{ config, lib, pkgs, ... }:

let
  talosRoot = "/etc/nixos/talos-host";
  passFile = "/etc/nixos/secrets/gunstein.passwd";

  disableLibvirtDefaultNet = pkgs.writeShellScript "disable-libvirt-default-network" ''
    set -euo pipefail

    # If libvirt default network exists, disable and remove it.
    if ${pkgs.libvirt}/bin/virsh -c qemu:///system net-info default >/dev/null 2>&1; then
      echo "[libvirt] Disabling/removing default network (avoids 192.168.122.0/24 route conflicts in nested libvirt)"
      ${pkgs.libvirt}/bin/virsh -c qemu:///system net-autostart default --disable || true
      ${pkgs.libvirt}/bin/virsh -c qemu:///system net-destroy default || true
      ${pkgs.libvirt}/bin/virsh -c qemu:///system net-undefine default || true
    fi

    # If virbr0 still exists, remove it (best-effort)
    if ${pkgs.iproute2}/bin/ip link show virbr0 >/dev/null 2>&1; then
      echo "[libvirt] Removing stale virbr0 bridge"
      ${pkgs.iproute2}/bin/ip link set virbr0 down || true
      ${pkgs.iproute2}/bin/ip link delete virbr0 type bridge || true
    fi

    # Show routes for debugging (helpful when you ssh back in)
    ${pkgs.iproute2}/bin/ip route | sed -n '1,80p' || true
  '';
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
    git vim tmux

    # Virtualization
    libvirt qemu_kvm qemu virt-manager virt-viewer

    # Talos/Kubernetes tooling
    talosctl kubectl
  ];

  virtualisation.libvirtd.enable = true;
  virtualisation.libvirtd.onBoot = "start";
  virtualisation.libvirtd.onShutdown = "shutdown";

  # IMPORTANT for nested libvirt:
  # libvirt's default network often uses 192.168.122.0/24, which can conflict with
  # the host VM's management network (also commonly 192.168.122.0/24).
  systemd.services.libvirt-disable-default-network = {
    description = "Disable libvirt default network (avoid nested 192.168.122.0/24 route conflicts)";
    after = [ "libvirtd.service" "virtqemud.service" "virtnetworkd.service" "network-online.target" ];
    wants = [ "libvirtd.service" "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = disableLibvirtDefaultNet;
    };
  };

  system.stateVersion = "24.11";
}
