# NixOS Talos VM Lab (nested libvirt)

This repo configures a **NixOS “host VM”** that runs **libvirt** and provisions **Talos Linux** inside **nested VMs**. The repo is designed to be **profile-driven** (lab1/lab2/…) and **maintainable without AI**: small scripts, clear inputs, predictable outputs.

**Architecture (quick mental model):** Outer hypervisor → runs `nixos-host` VM → inside `nixos-host` we run libvirt/QEMU → libvirt runs Talos VMs (control plane + optional workers). A profile defines libvirt network name/bridge/subnet and node specs (VM name, MAC, IP, resources).

**Repository layout:**
```
.
├─ flake.nix
├─ hosts/
│  └─ nixos-host.nix
├─ assets/
│  └─ metal-amd64.iso
├─ profiles/
│  ├─ lab1/
│  │  ├─ vars.env
│  │  └─ nodes.csv
│  └─ lab2/
│     ├─ vars.env
│     └─ nodes.csv
└─ scripts/
   ├─ install.sh
   ├─ lab.sh
   ├─ talos-provision.sh
   ├─ verify.sh
   ├─ diag.sh
   └─ common.sh
```

**Deploy locations on the NixOS host VM:** You work in `/home/gunstein/nixos-talos-vm-lab`. `install.sh` syncs the repo to `/etc/nixos/talos-host` and then runs `nixos-rebuild switch` from that flake tree. The scripts you run after deploy live at `/etc/nixos/talos-host/scripts/...`.

**IMPORTANT (nested libvirt can kill SSH):** In nested environments, libvirt’s `default` NAT network often uses `192.168.122.0/24` on `virbr0`. If your NixOS host VM itself is managed over `192.168.122.0/24` (common; e.g. you SSH to `192.168.122.161`), starting libvirt’s default network can create a route conflict and drop SSH. This repo disables/removes the libvirt `default` network on boot (and removes `virbr0` if it lingers). If SSH drops right after enabling libvirt or starting networks, suspect `default/virbr0` first and confirm with `ip route` + `virsh net-list --all`.

**Workflow (the intended stable path):**

1) Deploy host configuration and select profile:
```bash
sudo ./scripts/install.sh lab1
# or
sudo ./scripts/install.sh lab2
```
This: syncs repo → `/etc/nixos/talos-host`, writes active profile marker, ensures Talos ISO exists in deploy tree, runs `nixos-rebuild switch` (flake). It does **not** create VMs by itself.

2) Clean + provision a profile (recommended):
```bash
sudo /etc/nixos/talos-host/scripts/lab.sh lab2 wipe
sudo /etc/nixos/talos-host/scripts/lab.sh lab2 all
```
- `wipe` is destructive for that profile (VMs, disks, libvirt network, generated Talos state, kubeconfig).
- `all` runs `up` (network + VMs) then `provision` (generate config, apply-config, bootstrap, kubeconfig, wait for API).

3) Verify:
```bash
sudo /etc/nixos/talos-host/scripts/verify.sh lab2
```
This should confirm Talos API reachable, Kubernetes API reachable, `kubectl get nodes` works, and the control plane becomes Ready.

4) Diagnose (if something is wrong):
```bash
sudo /etc/nixos/talos-host/scripts/diag.sh lab2
```
This prints libvirt networks + bridge + routes, VM state + disks + NICs, DHCP leases, port checks (50000/6443), QEMU log tail, and best-effort `talosctl`/`kubectl` checks.

**Switching between lab1 and lab2:** Both profiles can remain in the repo. Switching is selecting a different profile and running the corresponding commands. Recommended safe switch (not running both at once):
```bash
# stop/delete lab1 resources (optional but recommended when switching labs)
sudo /etc/nixos/talos-host/scripts/lab.sh lab1 wipe

# deploy host config with lab2 active
sudo ./scripts/install.sh lab2

# bring up lab2 cleanly
sudo /etc/nixos/talos-host/scripts/lab.sh lab2 wipe
sudo /etc/nixos/talos-host/scripts/lab.sh lab2 all
```
Notes: You don’t need lab1 and lab2 running simultaneously. Each profile should use its own unique bridge name (e.g. `virbr-talosnet1`, `virbr-talosnet2`) to avoid collisions. The scripts attempt to resolve bridge conflicts automatically, but keeping profiles separate remains best practice.

**ISO handling:** Put the Talos ISO at `assets/metal-amd64.iso`. `install.sh` ensures it exists at `/etc/nixos/talos-host/assets/metal-amd64.iso`. `lab.sh` copies it to a libvirt-friendly cache path: `/var/lib/libvirt/images/metal-amd64.iso`.

**Outputs:** Per profile, generated Talos config is written under `${TALOS_DIR}/generated/` (`controlplane.yaml`, `worker.yaml`, `talosconfig`). Kubeconfig is written to a profile-specific root path (e.g. `/root/.kube/talos-lab-X.config`) and also to `/home/<user>/.kube/config` for convenience.

**Monitoring tips (use another terminal):**
```bash
watch -n1 "virsh -c qemu:///system net-list --all; echo; virsh -c qemu:///system list --all"
```
Useful network checks (especially if SSH behaves oddly):
```bash
ip route
ip addr
```
VM logs:
```bash
tail -n 200 /var/log/libvirt/qemu/<vmname>.log
```

**Disk pressure (NixOS host VM gets full):** Common causes are `/nix/store` growth (many rebuilds), journal logs, and libvirt images. Cleanup:
```bash
sudo nix-collect-garbage -d
sudo journalctl --vacuum-time=7d
sudo journalctl --vacuum-size=200M
```
Find large directories:
```bash
sudo du -xh /nix/store --max-depth=1 | sort -h | tail -n 20
sudo du -xh /var/lib/libvirt/images --max-depth=1 | sort -h | tail -n 20
sudo du -xh /var/log --max-depth=2 | sort -h | tail -n 20
```

**Design goals:** Profile-driven configuration (no magic global state), scripts are small and readable, deterministic “wipe → all → verify”, and debug output that points to the actual failing component (network, VM boot, Talos API, kube-apiserver).

**Common commands summary:**
```bash
# deploy host config for a profile
sudo ./scripts/install.sh lab1

# clean + provision a profile
sudo /etc/nixos/talos-host/scripts/lab.sh lab1 wipe
sudo /etc/nixos/talos-host/scripts/lab.sh lab1 all

# verify
sudo /etc/nixos/talos-host/scripts/verify.sh lab1

# diagnose
sudo /etc/nixos/talos-host/scripts/diag.sh lab1
```