# talos-host (NixOS + libvirt + Talos labs)

This repo provides a **repeatable**, **profile-driven** Talos lab setup on a single NixOS host.
The goal is that you can:

- make changes only in the repo
- run **a few simple commands**
- get an isolated lab environment per profile (`lab1`, `lab2`, …)
- reliably **wipe + recreate** a lab when it drifts out of sync

No “smart” auto-healing. If something is wrong, the scripts stop early and tell you to run `wipe`.

---

## How it works

### Source vs deploy
- You work in the repo:
  - `/home/gunstein/nixos-talos-vm-lab`
- The repo is synced to:
  - `/etc/nixos/talos-host`
- NixOS is built from the flake in `/etc/nixos/talos-host`

### Profiles
Each profile lives in:
- `profiles/<profile>/vars.env`
- `profiles/<profile>/nodes.csv`

A profile defines:
- libvirt network name (e.g. `talosnet-lab2`)
- bridge name (must be unique) (e.g. `virbr-talosnet-lab2`)
- gateway + DHCP range
- VM names, MACs, IPs, disk sizes, RAM, CPUs

### Script structure (intentionally simple)
- `scripts/install.sh <profile>`
  - sync repo -> `/etc/nixos/talos-host`
  - set active profile
  - run `nixos-rebuild switch`
- `scripts/lab.sh <profile> <command>`
  - `up`        : create network + VMs
  - `provision` : gen/apply/bootstrap/kubeconfig
  - `all`       : run `up` + `provision`
  - `wipe`      : remove everything for the profile (VM/disk/network/state)
  - `status`    : show current status

---

## Quick start

### 1) Deploy repo to /etc/nixos/talos-host and rebuild NixOS
Run from your repo checkout:

```bash
cd /home/gunstein/nixos-talos-vm-lab
sudo ./scripts/install.sh lab2
