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

  networking.hostName = "nixos-host";

  # Allow passwordless sudo for wheel group (needed for labctl from builder-vm)
  security.sudo.wheelNeedsPassword = false;
  networking.networkmanager.enable = true;

  # Lab hostnames for Traefik Ingress (via local proxy)
  networking.extraHosts = ''
    127.0.0.1 demo.lab.local grafana.lab.local prometheus.lab.local
  '';

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
    iproute2 iputils netcat-openbsd socat
    git vim tmux
    gnumake

    # Virtualization
    libvirt qemu_kvm qemu virt-manager virt-viewer

    # Talos/Kubernetes tooling
    talosctl kubectl

    # Local image build/push (demo backend)
    podman buildah skopeo curl

    # TLS certificate generation
    openssl
  ];

  virtualisation.libvirtd.enable = true;
  virtualisation.libvirtd.onBoot = "start";
  virtualisation.libvirtd.onShutdown = "shutdown";

  # Podman (daemonless) for building/pushing demo images
  virtualisation.podman.enable = true;
  virtualisation.podman.dockerCompat = true;

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




  # Local container image registry (HTTP) for the lab
  services.dockerRegistry = {
    enable = true;
    listenAddress = "0.0.0.0";
    port = 5000;
    enableDelete = true;
  };

  # Firewall: allow access to Traefik ingress (443) and container registry (5000)
  networking.firewall.allowedTCPPorts = [ 443 5000 ];

  # Ingress proxy: forward NixOS-host :443 to Traefik in the lab (hostNetwork mode).
  # The lab command `ingress` writes /etc/talos-ingress-proxy.env and restarts this service.
  systemd.services.talos-ingress-proxy = let
    proxyScript = pkgs.writeShellScript "talos-ingress-proxy" ''
      set -euo pipefail
      source /etc/talos-ingress-proxy.env
      exec ${pkgs.socat}/bin/socat \
        "TCP-LISTEN:''${LISTEN_PORT},fork,reuseaddr" \
        "TCP:''${TARGET_IP}:''${TARGET_PORT}"
    '';
  in {
    description = "Talos lab: forward NixOS-host :443 to Traefik Ingress";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    unitConfig = {
      ConditionPathExists = "/etc/talos-ingress-proxy.env";
    };

    serviceConfig = {
      ExecStart = proxyScript;
      Restart = "always";
      RestartSec = 2;
    };
  };

  system.stateVersion = "24.11";
}
