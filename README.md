# nixos-talos-vm-lab
Scripts and config for setting up a k8s home vm lab, using a nixos vm host with one or more talos vm nodes.

talos-host/
  flake.nix
  hosts/nixos-host.nix

  assets/
    metal-amd64.iso
    talosnet.xml.template

  profiles/
    lab1/
      vars.env
      nodes.csv
    lab2/
      vars.env
      nodes.csv

  scripts/
    install.sh
    talos-bootstrap.sh
    talos-verify.sh

Howto setup a new lab
Make a blank nixos vm, for example like this:
virsh destroy nixos-host 2>/dev/null || true
virsh undefine nixos-host --nvram 2>/dev/null || true
rm -f /var/lib/libvirt/images/nixos-host.qcow2
cp /usr/share/OVMF/OVMF_VARS_4M.fd /var/lib/libvirt/qemu/nvram/nixos-host_VARS.fd

virt-install \
  --name nixos-host \
  --memory 4096 \
  --vcpus 4 \
  --cpu host \
  --machine q35 \
  --boot loader=/usr/share/OVMF/OVMF_CODE_4M.fd,loader.readonly=yes,loader.type=pflash,nvram=/var/lib/libvirt/qemu/nvram/nixos-host_VARS.fd \
  --disk path=/var/lib/libvirt/images/nixos-host.qcow2,size=40,bus=virtio \
  --cdrom /var/lib/libvirt/images/iso/nixos-minimal-25.11.1335.09eb77e94fa2-x86_64-linux.iso \
  --network network=default,model=virtio \
  --graphics spice \
  --video virtio \
  --os-variant nixos-unstable

Download talos image and place it in assets folder.
scp this repository to you new/blank nixos vm


flake.nix blir brukt i install-steget, når vi kjører nixos-rebuild med --flake.

I opplegget vårt skjer det her:

1) I scripts/install.sh

Denne linja er det som “kaller” flaken:

nixos-rebuild switch --flake "/etc/nixos/talos-host#nixos-host"


Det betyr:

Nix leser flake.nix i mappa /etc/nixos/talos-host

Den slår opp outputen nixosConfigurations.nixos-host

Den bygger og aktiverer systemet basert på modulene du har definert (f.eks. hosts/nixos-host.nix)

2) Hva flaken faktisk gjør

flake.nix sitt ansvar er:

å definere hvilken NixOS-konfig som heter nixos-host

hvilke moduler som inngår (typisk ./hosts/nixos-host.nix)

hvilken nixpkgs versjon du “pinner” til (for reproduserbarhet)

3) Etter installasjonen

Etter at nixos-rebuild --flake ... er kjørt:

systemd-servicen talos-bootstrap.service finnes (fordi den ble definert i hosts/nixos-host.nix)

og install.sh gjør systemctl enable --now talos-bootstrap.service

Så: flake.nix brukes bare til å bygge/aktivere NixOS-oppsettet, ikke til å lage Talos direkte. Talos-oppsettet skjer via systemd-service + scriptet.

Hvordan du kan verifisere at flaken brukes

På maskinen der repoet ligger i /etc/nixos/talos-host:

nix flake show /etc/nixos/talos-host


Du skal se nixosConfigurations.nixos-host.

Og du kan “tørrkjøre” build:

nixos-rebuild build --flake /etc/nixos/talos-host#nixos-host


Hvis den bygger, blir flake.nix definitivt brukt korrekt.
