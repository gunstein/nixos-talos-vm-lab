# Talos Kubernetes Lab on NixOS

This repository sets up a **local Kubernetes lab based on Talos Linux**, running on **libvirt/KVM** on a **NixOS host**.

Goals:
- simple and predictable workflow
- only **one lab active at a time** (lab1, lab2, …)
- idempotent commands
- clear separation between *deployment* and *lab operations*

---

## Overview

### Roles

- `install.sh`  
  → deploys the repository to `/etc/nixos/talos-host`  
  → optionally runs `nixos-rebuild switch`  
  → **does not start any lab**

- `scripts/lab`  
  → the **only supported entrypoint** for lab operations  
  → always runs as root  
  → thin wrapper around `scripts/lab.sh`

- `scripts/lab.sh`  
  → actual orchestration logic (libvirt, Talos, Kubernetes)

---

## Repository layout (relevant)

```text
.
├── assets/
│   └── metal-amd64.iso
├── profiles/
│   ├── lab1/
│   │   ├── vars.env
│   │   └── nodes.csv
│   └── lab2/
│       ├── vars.env
│       └── nodes.csv
├── scripts/
│   ├── install.sh
│   ├── lab
│   ├── lab.sh
│   ├── lib.sh
│   ├── common.sh
│   ├── talos-provision.sh
│   └── talos-verify.sh
└── README.md
```

---

## 1. Initial deployment (or after repo changes)

Run this **from the repository clone**
(e.g. `~/nixos-talos-vm-lab`):

```bash
sudo ./scripts/install.sh
```

This will:
- rsync the repo to `/etc/nixos/talos-host`
- ensure `hardware-configuration.nix` is present
- ensure the Talos ISO exists in the deploy tree
- run `nixos-rebuild switch`  
  (can be skipped with `NO_REBUILD=1`)

After this step, you should work **only** from:

```bash
cd /etc/nixos/talos-host
```

---

## 2. Running a lab (standard workflow)

### Start lab1

```bash
sudo ./scripts/lab lab1 all
```

This performs, in order:
1. idempotent libvirt network setup
2. VM creation and startup
3. Talos provisioning
4. Kubernetes bootstrap
5. kubeconfig generation
6. cluster verification

After completion:

```bash
kubectl get nodes
```

should work without any extra configuration.

---

## 3. Switching between labs (one lab at a time)

This repository is designed to run **only one lab at a time**.

### Switch from lab1 → lab2

```bash
sudo ./scripts/lab lab1 wipe
sudo ./scripts/lab lab2 all
```

### Switch from lab2 → lab1

```bash
sudo ./scripts/lab lab2 wipe
sudo ./scripts/lab lab1 all
```

The `wipe` command removes:
- virtual machines
- VM disks
- libvirt network for the lab
- Talos state

---

## 4. Available commands

```bash
sudo ./scripts/lab <lab> <command>
```

| Command        | Description |
|---------------|-------------|
| `status`       | Show VM and network status |
| `up`           | Create network and VMs only |
| `provision`    | Talos configuration + bootstrap |
| `verify`       | Verify Talos and Kubernetes |
| `all`          | `up → provision → verify` |
| `wipe`         | Remove the entire lab |
| `net-recreate` | **Force** libvirt network recreation (destructive) |

> ⚠️ `net-recreate` should only be used if the network is broken.  
> Normal operation is fully idempotent and does **not** recreate networks automatically.

---

## 5. Kubeconfig handling

After running `lab <name> all`:

- kubeconfig is written to:
  - `/root/.kube/talos-<lab>.config`
  - `/home/<user>/.kube/config`

This means:

```bash
kubectl get nodes
```

works immediately for the active lab.

---

## 6. Design principles

- ❌ No `sudo -E`
- ❌ No `bash "$0"` wrappers
- ✅ Root escalation via `sudo env -i`
- ✅ Single entrypoint (`scripts/lab`)
- ✅ One active lab at a time
- ✅ Idempotent network and VM handling

These choices are intentional to avoid:
- shell recursion (SHLVL explosions)
- OOM kills
- SSH disconnects
- hidden or implicit side effects

---

## 7. Typical workflow (summary)

```bash
# deploy changes
sudo ./scripts/install.sh

# start a lab
cd /etc/nixos/talos-host
sudo ./scripts/lab lab1 all

# verify cluster
kubectl get nodes

# switch lab
sudo ./scripts/lab lab1 wipe
sudo ./scripts/lab lab2 all
```

---

## Status

✅ Talos Linux  
✅ Kubernetes bootstrap  
✅ libvirt / KVM  
✅ Stable and reproducible lab workflow  

Ready for further experimentation (CNI choices, storage, workloads, etc.).

---

## 8. Demo frontend (reachable from your LAN)

This repo includes a **super simple** frontend demo:
- static `nginx` pod
- `NodePort` service (fixed port `30080`)
- an optional helper forwarder on the NixOS-host VM (`:8080`)
- an optional Ubuntu-side forwarder so the demo is reachable from machines **outside the Ubuntu host**

### Step A: start the lab

```bash
sudo ./scripts/install.sh
cd /etc/nixos/talos-host
sudo ./scripts/lab lab1 all
```

### Step B: deploy + expose the demo frontend inside the NixOS-host VM

```bash
sudo ./scripts/lab lab1 demo-frontend
```

This will:
- `kubectl apply -f k8s/apps/frontend-demo`
- create `/etc/talos-frontend-proxy.env`
- restart the NixOS-host systemd service `talos-frontend-proxy`

You can verify inside the NixOS-host VM:

```bash
curl -sS http://127.0.0.1:8080/
```

### Step C: expose it to your LAN via Ubuntu

From Ubuntu (host), set up the small forwarder provided in `extras/ubuntu/`:

```bash
# in this repo on Ubuntu
cd extras/ubuntu
sudo ./install-frontend-forward.sh <NIXOS_HOST_VM_IP>
```

Then from any machine on your LAN:

- `http://<ubuntu-lan-ip>:8080/`

> Tip: To find the NixOS-host VM IP from Ubuntu, try:
> `sudo virsh domifaddr <vm-name>`

## Developer tools: doctor, lint and fmt

This repo includes a few small helper commands that make it easier to debug issues and keep the bash code consistent.

### Devshell (recommended)

If you have Nix with flakes enabled, you can get the right tool versions (shellcheck/shfmt) without installing anything globally:

```bash
nix develop
```

To run a single command without entering an interactive shell:

```bash
nix develop -c <command>
```

Example:

```bash
nix develop -c ./scripts/lint
```

### `./scripts/doctor` — read-only health checks

`doctor` checks that your host/profile has what it needs for the lab to work (tools, `/dev/kvm`, libvirt access, the Talos ISO, and basic profile validation). It does not make destructive changes.

Run a general check:

```bash
./scripts/doctor
```

Validate a specific profile:

```bash
./scripts/doctor lab1
./scripts/doctor lab2
```

If the cluster is not up yet (or you want to skip k8s checks):

```bash
./scripts/doctor lab1 --no-k8s
```

**Typical workflow:**  
Run `doctor` before starting a new lab, and when something fails: “Run doctor and paste the output”.

### `./scripts/lint` — static bash checks (ShellCheck)

Runs ShellCheck on the scripts and catches common bash issues early.

```bash
./scripts/lint
```

Recommended via devshell (ensures consistent results for everyone):

```bash
nix develop -c ./scripts/lint
```

### `./scripts/fmt` — format bash scripts (shfmt)

Formats bash scripts with a consistent style (makes the code easier to read, teach, and maintain).

```bash
./scripts/fmt
```

Via devshell:

```bash
nix develop -c ./scripts/fmt
```

**Suggested pre-commit routine:**

```bash
./scripts/fmt
./scripts/lint
```

### Tips for contributors/maintenance

- If you change scripts: run `fmt` + `lint` before you commit.
- If a lab fails: run `doctor` first — it often reveals environment/network issues quickly.
