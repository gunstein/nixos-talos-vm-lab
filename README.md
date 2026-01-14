# Talos Kubernetes Lab on NixOS

This repository sets up a **local Kubernetes lab based on Talos Linux**, running on **libvirt/KVM** on a **NixOS host**.

Goals:
- simple and predictable workflow
- only **one lab active at a time** (lab1, lab2, …)
- idempotent commands
- clear separation between *deployment* and *lab operations*

---

## Prerequisites

Before using this repo, you need:

1. A host machine with libvirt/KVM (e.g., Ubuntu or another Linux distro)
2. A NixOS VM running on that host (the "NixOS-host")
3. The Talos ISO downloaded to the correct location

---

## 0. Creating the NixOS-host VM

This section explains how to create the NixOS VM that will host the Talos lab. Skip this if you already have a NixOS-host VM.

### 0.1 Create the VM with virt-install

On your host machine (e.g., Ubuntu):

```bash
# Clean up any existing VM with the same name
virsh destroy nixos-host 2>/dev/null || true
virsh undefine nixos-host --nvram 2>/dev/null || true
rm -f /var/lib/libvirt/images/nixos-host.qcow2

# Prepare UEFI vars
cp /usr/share/OVMF/OVMF_VARS_4M.fd /var/lib/libvirt/qemu/nvram/nixos-host_VARS.fd

# Create the VM (8GB RAM recommended for running Talos VMs inside)
virt-install \
  --name nixos-host \
  --memory 8192 \
  --vcpus 4 \
  --cpu host \
  --machine q35 \
  --boot loader=/usr/share/OVMF/OVMF_CODE_4M.fd,loader.readonly=yes,loader.type=pflash,nvram=/var/lib/libvirt/qemu/nvram/nixos-host_VARS.fd \
  --disk path=/var/lib/libvirt/images/nixos-host.qcow2,size=40,bus=virtio \
  --cdrom /var/lib/libvirt/images/iso/nixos-minimal-25.11.xxxx-x86_64-linux.iso \
  --network network=default,model=virtio \
  --graphics spice \
  --video virtio \
  --os-variant nixos-unstable
```

Download the NixOS minimal ISO from https://nixos.org/download/ and place it in `/var/lib/libvirt/images/iso/`.

### 0.2 Install NixOS

In the VM console (via virt-manager or virsh console):

```bash
# Set Norwegian keyboard layout
sudo loadkeys no

# Set password for nixos user (so you can SSH in)
passwd nixos

# Start SSH and find the IP
sudo -i
systemctl start sshd
ip -br a
```

SSH in from your host (much easier to work with):

```bash
ssh nixos@<vm-ip>
sudo -i
```

Partition and format the disk:

```bash
# Partition
parted /dev/vda -- mklabel gpt
parted /dev/vda -- mkpart ESP fat32 1MiB 512MiB
parted /dev/vda -- set 1 esp on
parted /dev/vda -- mkpart primary 512MiB 100%

# Format
mkfs.fat -F32 /dev/vda1
mkfs.ext4 /dev/vda2

# Mount
mount /dev/vda2 /mnt
mkdir -p /mnt/boot
mount /dev/vda1 /mnt/boot
```

Generate and edit config:

```bash
nixos-generate-config --root /mnt
nano /mnt/etc/nixos/configuration.nix
```

Minimal required changes in `configuration.nix`:

```nix
# Enable SSH
services.openssh.enable = true;

# Create your user
users.users.gunstein = {
  isNormalUser = true;
  extraGroups = [ "wheel" ];
};
```

Install and reboot:

```bash
nixos-install
reboot
```

After reboot, log in as root and set password for your user:

```bash
passwd gunstein
```

### 0.3 Download the Talos ISO

Download `metal-amd64.iso` from https://github.com/siderolabs/talos/releases and place it in the `assets/` folder of this repo:

```bash
# On your laptop/workstation
cd nixos-talos-vm-lab
mkdir -p assets
# Download to assets/metal-amd64.iso
```

### 0.4 Copy the repo to NixOS-host

From your laptop/workstation:

```bash
# Direct copy
scp -r nixos-talos-vm-lab gunstein@<nixos-host-ip>:~/

# Or via jump host
scp -r -J user@jump-host nixos-talos-vm-lab gunstein@<nixos-host-ip>:~/
```

Or use rsync for incremental updates:

```bash
rsync -a --delete -e "ssh -J user@jump-host" \
  nixos-talos-vm-lab/ gunstein@<nixos-host-ip>:~/nixos-talos-vm-lab/
```

### 0.5 Snapshots (recommended)

Take snapshots at key points so you can restore quickly:

```bash
# On the host machine (not inside the VM)

# After fresh NixOS install (before any lab setup)
virsh snapshot-create-as nixos-host fresh-install "Clean NixOS install"

# After running install.sh (NixOS configured for Talos lab)
virsh snapshot-create-as nixos-host configured "Ready for Talos lab"

# List snapshots
virsh snapshot-list nixos-host

# Restore to a snapshot
virsh snapshot-revert nixos-host fresh-install

# Delete a snapshot
virsh snapshot-delete nixos-host <snapshot-name>
```

**Tip:** Take a snapshot before major changes. If something breaks, you can restore in seconds instead of reinstalling.

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

This section explains the key folders/files you’ll touch most often.

```text
.
├── flake.nix
├── hosts/
│   └── nixos-host.nix
├── profiles/
│   ├── lab1/
│   │   ├── vars.env
│   │   └── nodes.csv
│   └── lab2/
│       ├── vars.env
│       └── nodes.csv
├── apps/
│   └── demo-backend/
│       ├── Dockerfile
│       └── main.go
├── scripts/
│   ├── common.sh
│   ├── install.sh
│   ├── lab.sh
│   ├── demo-backend-build.sh
│   ├── talos-provision.sh
│   ├── talos-verify.sh
│   ├── doctor
│   ├── lint
│   └── fmt
├── k8s/
│   ├── addons/
│   │   ├── traefik.yaml
│   │   ├── prometheus.yaml
│   │   ├── grafana.yaml
│   │   └── ...
│   └── apps/
│       └── frontend-demo/
│           ├── 00-namespace.yaml
│           ├── 10-frontend-configmap.yaml
│           ├── 15-frontend-nginx-config.yaml
│           ├── 20-frontend-deployment.yaml
│           ├── 30-frontend-service.yaml
│           ├── 35-ingress.yaml
│           ├── 50-backend-deployment.yaml
│           └── 60-backend-service.yaml
├── assets/
│   └── metal-amd64.iso
└── extras/
    └── ubuntu/
        └── install-frontend-forward.sh
```

### What each part does

- **`flake.nix`**
  - Defines the NixOS configuration and the dev shell (`nix develop`) for tools like `shellcheck` and `shfmt`.

- **`hosts/nixos-host.nix`**
  - NixOS configuration for the **NixOS-host VM** (libvirt/qemu, kubectl/talosctl tooling, and the `talos-frontend-proxy` service).

- **`profiles/<lab>/vars.env` + `profiles/<lab>/nodes.csv`**
  - A “lab profile” defines the lab network and the VM nodes.
  - `vars.env` holds lab-wide settings (subnet, gateways, names, etc.).
  - `nodes.csv` lists nodes (control-plane/worker) with IP/MAC and disk mapping.

- **`scripts/`**
  - **`install.sh`**: syncs repo → `/etc/nixos/talos-host` on the NixOS-host VM and runs `nixos-rebuild switch`.
  - **`lab.sh`**: the main CLI entrypoint (`./scripts/lab <profile> ...`).
  - **`talos-provision.sh` / `talos-verify.sh`**: Talos bootstrap + verification steps.
  - **`doctor`**: read-only health checks for the host/profile.
  - **`lint` / `fmt`**: bash linting (ShellCheck) and formatting (shfmt).
  - **`common.sh`**: shared helpers and error handling (ERR trap).

- **`apps/demo-backend/`**
  - Source code for the demo backend (Go HTTP server + Dockerfile).
  - Built with Podman and pushed to the local registry by `scripts/demo-backend-build.sh`.

- **`k8s/apps/frontend-demo/`**
  - Kubernetes manifests deployed by `./scripts/lab <profile> demo`.
  - Contains both **frontend + backend**; frontend proxies `/api/*` to the backend.
  - Frontend is exposed via NodePort `30080`, then forwarded to `:8080` by the NixOS-host proxy.

- **`assets/metal-amd64.iso`**
  - Talos ISO used for bootstrapping the Talos VMs (copied/managed by `install.sh` in your setup).

- **`extras/ubuntu/`**
  - Optional helpers for the Ubuntu host, e.g. port forwarding from Ubuntu → NixOS-host VM.

### Runtime paths (on the NixOS-host VM)

In your workflow, the repo is synced to:

- `/etc/nixos/talos-host`

Some runtime/host-local files live outside the repo:

- `/etc/nixos/secrets/` (passwords/keys, not committed)
- `/etc/talos-frontend-proxy.env` (generated by the demo command)

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

### Skipping the rebuild

If you only changed bash scripts (not `.nix` files), you can skip the rebuild:

```bash
NO_REBUILD=1 sudo ./scripts/install.sh
```

This is useful when:
- You're iterating on scripts and want faster deploys
- The NixOS configuration hasn't changed
- You're offline and can't download packages

**Note:** If you changed any `.nix` files (e.g. `hosts/nixos-host.nix`, `flake.nix`), you must run the full rebuild for those changes to take effect.

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
7. Traefik Ingress with TLS
8. Demo app with PostgreSQL database
9. Prometheus + Grafana monitoring

After completion, all services are accessible via HTTPS:
- https://demo.lab.local
- https://grafana.lab.local (admin/admin)
- https://prometheus.lab.local

```bash
kubectl get nodes
```

should work without any extra configuration.

See [section 11](#11-ingress-with-traefik-tls) for how to configure hosts file and SSH tunnel for browser access.

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

## 8. Demo stack

The demo stack is deployed automatically when you run `lab1 all`. It includes:

- **Frontend**: `demo-frontend` (nginx) serves a static page and proxies `/api/*` to the backend
- **Backend**: `demo-backend` (Go HTTP server) with `/api/hello` and `/api/items` endpoints
- **Database**: PostgreSQL via CloudNativePG
- **Exposure**: via Traefik Ingress at `https://demo.lab.local`

### Test the demo (on NixOS-host)

```bash
# Frontend page
curl -k https://demo.lab.local/

# Backend hello endpoint
curl -k https://demo.lab.local/api/hello

# Database endpoints
curl -k https://demo.lab.local/api/items
curl -k -X POST https://demo.lab.local/api/items \
  -H "Content-Type: application/json" \
  -d '{"name":"my first item"}'
curl -k https://demo.lab.local/api/items
```

### Access from laptop via SSH tunnel

```bash
# Start tunnel (keep open)
sudo ssh -L 443:127.0.0.1:443 -J user@jump-host gunstein@nixos-host

# Add to /etc/hosts on laptop
127.0.0.1 demo.lab.local grafana.lab.local prometheus.lab.local

# Open in browser
https://demo.lab.local
```

### Connect to the database directly

```bash
kubectl -n demo exec -it demo-db-1 -- psql -U demo -d demo
```

### Deploy demo separately (without database)

If you want to run the demo without a database:

```bash
sudo ./scripts/lab lab1 demo
```

This deploys frontend + backend but without PostgreSQL. The `/api/items` endpoint will return 503.

### Kubernetes objects

- Namespace: `demo`
- Deployments: `demo-frontend`, `demo-backend`
- Services: `demo-frontend` (ClusterIP), `demo-backend` (ClusterIP)
- Ingress: `demo-frontend` (routes `demo.lab.local` via Traefik)
- Database: `demo-db` (CloudNativePG cluster)

### Notes

- The manifests are compatible with PodSecurity `restricted`
- Backend image is built with Podman and pushed to local registry
- Database uses `local-path-provisioner` for storage


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

## 10. Monitoring and logging stack

The lab includes a complete observability stack for learning debugging and monitoring:

- **Prometheus** - metrics collection
- **Loki** - log aggregation
- **Promtail** - log collector (runs on all nodes)
- **Grafana** - visualization (pre-configured with both datasources)

### Deploy monitoring

Monitoring is deployed automatically with `lab1 all`. To deploy separately:

```bash
sudo ./scripts/lab lab1 monitoring
```

This will:
- Install `local-path-provisioner` for storage
- Deploy Prometheus (metrics collection, 7-day retention)
- Deploy Loki (log aggregation)
- Deploy Promtail (log collector DaemonSet)
- Deploy Grafana (visualization, pre-configured with Prometheus and Loki datasources)

### Access Grafana

From inside the NixOS-host VM:

```bash
# Test that Grafana responds
curl -s http://127.0.0.1:3000/api/health

# Credentials: admin / admin
```

Anonymous read-only access is also enabled for convenience.

#### Access from a remote machine via SSH tunnel

If you're working from a machine that can SSH to the NixOS-host VM:

```bash
# Forward port 3000 to your local machine
ssh -L 3000:127.0.0.1:3000 <user>@<nixos-host-ip>

# Then open in browser: http://127.0.0.1:3000
```

#### Access via SSH jump host

If you access the NixOS-host VM through an intermediate host (e.g., laptop → Ubuntu → NixOS-host):

```bash
# Example: laptop → Ubuntu (192.168.0.104) → NixOS-host (192.168.122.161)
ssh -L 3000:127.0.0.1:3000 -J user@192.168.0.104 gunstein@192.168.122.161

# Keep the session open, then open in browser: http://127.0.0.1:3000
```

Replace the IPs and usernames with your actual values.

### Access Prometheus

Prometheus is only exposed as ClusterIP. Use port-forward to access its UI:

```bash
kubectl -n monitoring port-forward svc/prometheus 9090:9090
# Then open http://127.0.0.1:9090
```

### What gets monitored

Out of the box, Prometheus scrapes:
- Itself (prometheus job)
- Any pod with annotation `prometheus.io/scrape: "true"` and `prometheus.io/port: "<port>"`

To add metrics to your own applications, add these annotations to your pod template:

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8000"
```

### Viewing logs with Loki

All pod logs are automatically collected by Promtail and stored in Loki. To view logs:

1. Open Grafana: `https://grafana.lab.local`
2. Go to **Explore** (compass icon in sidebar)
3. Select **Loki** as datasource (dropdown at top)
4. Run a query, for example:
   - `{namespace="demo"}` - all logs from demo namespace
   - `{app="demo-backend"}` - logs from backend pods
   - `{namespace="kube-system"}` - system logs

Example queries:

```logql
# All logs from demo namespace
{namespace="demo"}

# Backend errors only
{app="demo-backend"} |= "error"

# Logs from last 5 minutes with rate
rate({namespace="demo"}[5m])
```

### Notes

- Prometheus uses 5Gi storage, Loki uses 5Gi, Grafana uses 1Gi
- All require `local-path-provisioner` (installed automatically)
- Promtail runs as DaemonSet on all nodes (including control-plane)
- Logs are retained for 7 days by default


## 11. Ingress with Traefik (TLS)

Traefik Ingress Controller routes all traffic through HTTPS on port 443 with hostname-based routing. It is installed automatically as part of `lab all`.

### How it works

When you run `./scripts/lab lab1 all`, Traefik is automatically installed with:
- A self-signed CA and wildcard certificate for `*.lab.local`
- TLS termination on port 443
- HTTP→HTTPS redirect

Services deployed with `demo` or `monitoring` automatically get Ingress resources.

### Configure hosts file

Add to `/etc/hosts` on the machine where you run your browser:

```bash
# If accessing via SSH tunnel
127.0.0.1 demo.lab.local grafana.lab.local prometheus.lab.local

# Or if accessing from another machine, use the NixOS-host IP
192.168.122.161 demo.lab.local grafana.lab.local prometheus.lab.local
```

### Access services via SSH tunnel

There are two options for tunneling HTTPS traffic to your laptop:

**Option 1: Forward port 443 (requires sudo)**

```bash
# Requires sudo because port 443 is privileged
sudo ssh -L 443:127.0.0.1:443 -J user@ubuntu-host gunstein@nixos-host

# Add to /etc/hosts on laptop
127.0.0.1 demo.lab.local grafana.lab.local prometheus.lab.local

# Open in browser
https://demo.lab.local
https://grafana.lab.local
https://prometheus.lab.local
```

**Option 2: Forward to non-privileged port (no sudo needed)**

```bash
# Forward to port 8443 instead (no sudo required)
ssh -L 8443:127.0.0.1:443 -J user@ubuntu-host gunstein@nixos-host

# Add to /etc/hosts on laptop
127.0.0.1 demo.lab.local grafana.lab.local prometheus.lab.local

# Open in browser (note the :8443 port)
https://demo.lab.local:8443
https://grafana.lab.local:8443
https://prometheus.lab.local:8443
```

**Important:** The `/etc/hosts` entry is required because Traefik uses Host-header based routing. Without it, you'll get a 404 error.

### Trust the CA certificate

To avoid browser warnings, import the CA certificate:

```bash
# The CA cert is at:
/etc/nixos/talos-host/certs/ca.crt

# Copy it to your machine and import into your browser/OS
```

**macOS:**
```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt
```

**Linux (Chrome/Chromium):**
```bash
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "Talos Lab CA" -i ca.crt
```

**Firefox:** Settings → Privacy & Security → Certificates → View Certificates → Import

### Traefik Dashboard

```bash
# Port-forward to access dashboard
kubectl -n traefik-system port-forward svc/traefik 8080:8080
# Then open http://127.0.0.1:8080

# Or access via NodePort
http://<node-ip>:30088
```

### Architecture

```
Browser → NixOS-host:443 → Traefik (NodePort 30443)
                                 ├── demo.lab.local      → demo-frontend
                                 ├── grafana.lab.local   → Grafana
                                 └── prometheus.lab.local → Prometheus
```

### Manual Ingress command

If you need to reinstall or reconfigure Ingress manually:

```bash
sudo ./scripts/lab lab1 ingress
```

### Notes

- Traefik is installed automatically in `cmd_all()`
- CA and certificates are stored in `/etc/nixos/talos-host/certs/`
- Certificates are valid for 1 year, CA for 10 years
- Legacy proxies (port 8080, 3000) still work for backward compatibility
- Traefik exposes Prometheus metrics (auto-scraped)


## Using the Makefile (optional)

This repo ships with a small `Makefile` that provides convenient shortcuts for the existing scripts.
It does **not** replace the scripts in `./scripts/` — it only calls them.

### Common commands

```bash
# Show available targets
make help

# Health checks (read-only)
make doctor LAB=lab1
make doctor LAB=lab2

# Create/boot/provision/verify a lab
make lab-all LAB=lab1
make lab-all LAB=lab2

# Build, deploy and expose the demo (frontend + backend)
make demo LAB=lab1
make demo LAB=lab2

# Format and lint bash scripts
make fmt
make lint
```

### Run fmt/lint via the Nix devshell

If you use `nix develop`, you can run formatting and linting through the devshell:

```bash
make fmt-nix
make lint-nix
```

### Notes

- `LAB` defaults to `lab1` if not set.
- Targets that need root privileges use `sudo` by default. You can override it:

```bash
make lab-all LAB=lab1 SUDO=""
```