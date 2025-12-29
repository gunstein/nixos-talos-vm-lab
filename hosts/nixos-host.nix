{ config, lib, pkgs, ... }:

let
  talosRoot = "/etc/nixos/talos-host";
  passFile = "/etc/nixos/secrets/gunstein.passwd";
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  # Enable modern Nix commands by default.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking.hostName = "nixos";
  networking.networkmanager.enable = true;

  services.openssh.enable = true;

  # UEFI boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Keep users mutable so passwords don't get reset on rebuild.
  users.mutableUsers = true;

  users.users.gunstein = {
    isNormalUser = true;
    extraGroups = [ "wheel" "libvirtd" ];
    # Host-local secret written by install.sh; if missing, user can set password manually.
    initialHashedPassword =
      lib.mkIf (builtins.pathExists passFile) (builtins.readFile passFile);
  };

  environment.systemPackages = with pkgs; [
    bash
    coreutils
    gnugrep
    gawk
    util-linux
    iproute2
    iputils
    netcat-openbsd
    git
    vim

    # Virtualization
    libvirt
    qemu_kvm
    qemu
    virt-manager   # provides virt-install
    virt-viewer

    # Talos/Kubernetes tooling
    talosctl
    kubectl
  ];

  virtualisation.libvirtd.enable = true;
  virtualisation.libvirtd.onBoot = "start";
  virtualisation.libvirtd.onShutdown = "shutdown";

  # Required; never change after initial install.
  system.stateVersion = "24.11";

  systemd.services.talos-bootstrap = {
    description = "Bootstrap libvirt network + Talos VMs (profile-driven)";
    after = [ "libvirtd.service" "network-online.target" ];
    wants = [ "libvirtd.service" "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    # StartLimit belongs to the unit section (not [Service]).
    startLimitIntervalSec = 300;
    startLimitBurst = 3;

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash ${talosRoot}/scripts/talos-bootstrap.sh";
      Restart = "on-failure";
      RestartSec = "10s";
    };

    path = with pkgs; [
      bash coreutils gnugrep gawk util-linux
      iproute2 iputils netcat-openbsd
      libvirt qemu_kvm qemu virt-manager
    ];
  };

  systemd.services.talos-provision = {
    description = "Provision Talos (gen/apply/bootstrap/kubeconfig)";
    after = [ "talos-bootstrap.service" ];
    requires = [ "talos-bootstrap.service" ];
    wantedBy = [ "multi-user.target" ];

    startLimitIntervalSec = 600;
    startLimitBurst = 3;

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash ${talosRoot}/scripts/talos-provision.sh";
      Restart = "on-failure";
      RestartSec = "10s";
    };

    path = with pkgs; [
      bash coreutils gnugrep gawk util-linux
      iproute2 iputils netcat-openbsd
      libvirt
      talosctl
      kubectl
    ];
  };
}
