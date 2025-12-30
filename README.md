# NixOS + Talos Kubernetes Lab

This repository sets up **Talos Kubernetes clusters as VMs on a NixOS host**
using `libvirt/virsh` and a small set of shell scripts.

The setup is designed for **reproducibility, experimentation, and debugging** —
not for running many clusters in parallel.

---

## Architecture Overview

- **NixOS VM** acts as the *host*
- The host runs **Talos Linux** inside libvirt VMs
- Each *lab* (`lab1`, `lab2`, …):
  - is fully isolated
  - has its own libvirt network
  - has its own Talos state directory
  - has its own kubeconfig file
- Labs are intended to be run **one at a time**

> ⚠️ Important  
> The scripts are **not designed for multiple labs running simultaneously**
> on a small host VM.  
> Always *wipe* before switching labs.

---

## Important Paths

- `/etc/nixos/talos-host/` – deployed repo and scripts
- `/var/lib/talos-lab-*` – Talos state per lab
- `/var/lib/libvirt/images/` – VM disks
- `~/.kube/talos-lab-*.config` – kubeconfig per lab

---

## Basic Workflow

### Start a lab (clean start)

```bash
sudo /etc/nixos/talos-host/scripts/lab.sh lab1 wipe
sudo /etc/nixos/talos-host/scripts/lab.sh lab1 all
```

---

### Switch from lab1 → lab2 (recommended & safe)

```bash
sudo /etc/nixos/talos-host/scripts/lab.sh lab1 wipe
sudo /etc/nixos/talos-host/scripts/lab.sh lab2 wipe
sudo /etc/nixos/talos-host/scripts/lab.sh lab2 all
```

Why wipe the *target lab* as well?

- `lab.sh` **reuses existing VMs if they exist**
- Old VM definitions may have:
  - wrong network
  - wrong MAC address
  - stale disk / broken Talos state
- This causes Talos API (`:50000`) to never come up

Wiping guarantees a clean, correct VM definition.

---

## Diagnostic & Verification Tools

### `diag.sh` — Host & lab diagnostics

Use this when:
- a lab fails to start
- Talos API is not reachable
- you want a quick system overview

Example:

```bash
sudo /etc/nixos/talos-host/scripts/diag.sh lab1
```

Typical output includes:
- running libvirt networks and VMs
- Talos state directories
- disk usage and memory
- kubeconfig paths
- basic network information

This script is **read-only** and safe to run at any time.

---

### `verify.sh` — Talos & Kubernetes verification

Use this after a lab has started to verify it is actually healthy.

Example:

```bash
sudo /etc/nixos/talos-host/scripts/verify.sh lab1
```

Typical checks:
- Talos API reachability
- `talosctl health`
- Kubernetes API access
- `kubectl get nodes`
- basic cluster sanity checks

If `verify.sh` fails, the lab is **not usable yet**, even if VMs appear running.

---

## Common Commands

### Which lab am I connected to?

```bash
kubectl cluster-info
kubectl get nodes -o wide
```

- `192.168.123.x` → lab1
- `192.168.124.x` → lab2

---

### Which VMs are running?

```bash
sudo virsh -c qemu:///system list --all
```

---

### DHCP / IP debugging

```bash
sudo virsh -c qemu:///system net-dhcp-leases talosnet1
sudo virsh -c qemu:///system net-dhcp-leases talosnet2
```

---

### Talos console access

```bash
sudo virsh -c qemu:///system console talos1-cp-1
# exit with Ctrl+]
```

---

## Common Problems & Fixes

### ❌ `Talos API not reachable :50000`

**Cause**
- VM already existed and was reused
- VM definition does not match current lab config

**Fix**
```bash
sudo /etc/nixos/talos-host/scripts/lab.sh <lab> wipe
sudo /etc/nixos/talos-host/scripts/lab.sh <lab> all
```

---

### ❌ SSH session drops when starting a lab

**Cause**
- `install.sh` runs `nixos-rebuild switch`
- network restart or OOM kills ssh

**Fix**
- Use `install.sh` **only** when Nix config changes
- Use `lab.sh` for daily lab operations

---

### ❌ NixOS host disk fills up

Clean unused Nix store data:

```bash
sudo nix-collect-garbage -d
sudo nix-store --optimise
```

---

## Key Rules (Short Version)

- ✅ Run **one lab at a time**
- ✅ Always wipe before `all` if a lab may exist
- ❌ Do not trust existing VM definitions
- ❌ Do not use `install.sh` to switch labs

---

## Future Improvements (Ideas)

- Make `lab.sh` VM handling idempotent:
  - verify network + MAC
  - auto-recreate VM on mismatch
- Add `switch-lab.sh` helper
- Improve logging during `wait_port`

---

This repository is intentionally **lab-focused**, not production-ready,
but provides strong control and visibility into Talos + Kubernetes behavior.