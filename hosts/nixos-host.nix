{ config, pkgs, ... }:
{
  services.openssh.enable = true;
  virtualisation.libvirtd.enable = true;

  networking.networkmanager.enable = true;

  users.users.gunstein = {
    isNormalUser = true;
    extraGroups = [ "wheel" "libvirtd" "networkmanager" ];
    packages = with pkgs; [ ];
  };

  environment.systemPackages = with pkgs; [
    libvirt qemu_kvm qemu
    virt-manager   # gir deg virt-install
    iproute2 iputils bridge-utils netcat-openbsd
    jq curl gnugrep gawk coreutils
    tmux
    talosctl kubectl
    gettext # envsubst
  ];

  systemd.services.talos-bootstrap = {
    description = "Bootstrap Talos on libvirt (profile-driven)";
    after = [ "network-online.target" "libvirtd.service" ];
    wants = [ "network-online.target" "libvirtd.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "10s";
      Environment = [
        "PROFILE=lab1" # install.sh setter riktig
      ];
      ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/talos-host/scripts/talos-bootstrap.sh";
    };
  };
}
