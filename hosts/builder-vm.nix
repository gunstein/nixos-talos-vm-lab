{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking.hostName = "builder";
  networking.networkmanager.enable = true;

  services.openssh.enable = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  users.mutableUsers = true;

  users.users.gunstein = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };

  # Python environment for labctl
  environment.systemPackages = with pkgs; [
    # Core tools
    bash
    coreutils
    gnugrep
    gawk
    git
    vim
    tmux

    # SSH and networking
    openssh
    curl
    rsync

    # Python for labctl
    python311
    python311Packages.pip
    python311Packages.virtualenv

    # Useful for debugging
    jq
    htop
  ];

  # Allow passwordless sudo for wheel group (needed for some operations)
  security.sudo.wheelNeedsPassword = false;

  system.stateVersion = "24.11";
}
