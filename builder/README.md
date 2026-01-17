# Builder VM - Lab Provisioning and Testing

This directory contains the Python tooling for automated lab provisioning and testing.
It's designed to run on a separate "builder" VM (nixos-control) that controls the nixos-host remotely.

## Architecture

```
nixos-control (this code)
├── labctl deploy
│   ├── Copy repo to nixos-host via rsync
│   ├── Run install.sh (NixOS rebuild)
│   ├── Wipe existing lab
│   └── Provision new lab
└── labctl test
    └── Run tests via SSH tunnel

nixos-host
└── Talos lab (VMs)
    ├── talos-cp-1
    └── (workers)
```

## Setup

### Option 1: Fresh NixOS builder-vm

If setting up a new NixOS VM for builder:

1. Install NixOS (minimal install is fine)
2. Copy this repo to the VM
3. Run the install script:

```bash
cd ~/nixos-talos-vm-lab/builder
sudo ./install.sh
```

This will:
- Apply the NixOS configuration (`builder-vm`)
- Create Python venv with labctl
- Create config file at `~/.config/labctl/config.toml`

4. Edit config file with nixos-host IP:

```bash
nano ~/.config/labctl/config.toml
```

### Option 2: Existing system

1. Ensure Python 3.11+ and pip are installed
2. Install labctl:

```bash
cd ~/nixos-talos-vm-lab/builder
pip install -e ".[test]"
```

3. Create config file manually (see Configuration section)

### Configure SSH access

```bash
# Generate SSH key if needed
ssh-keygen -t ed25519

# Copy to nixos-host
ssh-copy-id gunstein@<nixos-host-ip>

# Test connection
ssh gunstein@<nixos-host-ip> "echo 'Connection OK'"
```

## Configuration

labctl uses a TOML config file at `~/.config/labctl/config.toml`:

```toml
[lab]
profile = "lab1"
local_repo = "~/nixos-talos-vm-lab"

[nixos-host]
host = "192.168.0.106"
user = "gunstein"
# port = 22
# ssh_key = "~/.ssh/id_rsa"

[tunnel]
local_port = 8443
remote_port = 443
```

View current configuration:

```bash
labctl config
```

Environment variables can override config file values:
- `NIXOS_HOST`, `NIXOS_USER`, `NIXOS_PORT`
- `LAB_PROFILE`, `TUNNEL_PORT`, `SSH_KEY_PATH`

## Usage

### Deploy lab (full workflow)

```bash
# Full deploy: wipe + install + provision (with confirmation)
labctl deploy

# Skip confirmation
labctl deploy -y
```

### Partial operations

```bash
# Only copy repo and run install.sh (no wipe/provision)
labctl deploy --install

# Only wipe existing lab
labctl deploy --wipe

# Only provision (no wipe first)
labctl deploy --provision
```

### Status and diagnostics

```bash
labctl status    # Show lab status
labctl doctor    # Run health checks
labctl config    # Show current configuration
```

### Run tests

```bash
# All tests (common + profile-specific)
labctl test

# Smoke tests only
labctl test --smoke

# Specific test pattern
labctl test -k "demo"
```

### Options

```bash
# Different host/user (overrides config file)
labctl --host 192.168.1.100 --user myuser deploy

# Different lab profile
labctl --profile lab2 deploy

# Verbose output
labctl -v deploy
```

## Test structure

Tests are organized by profile:

```
tests/
├── conftest.py         # Shared fixtures
├── common/             # Tests for all profiles
│   └── test_cluster.py # Nodes ready, system pods, Traefik
└── lab1/               # Tests specific to lab1
    ├── test_demo.py    # Demo app endpoints
    ├── test_monitoring.py  # Grafana, Prometheus
    └── test_resilience.py  # Pod recovery, data persistence
```

`labctl test` automatically runs `common/` + `<profile>/` tests.

### Test categories

- **smoke** - Basic checks that the lab is functioning
  - Nodes ready
  - Core pods running
  - Demo endpoints responding
  - Monitoring stack up

- **resilience** - Recovery from failures
  - Pod deletion and recovery
  - Database data persistence

## Development

```bash
# Install with test and dev dependencies
pip install -e ".[test,dev]"

# Run linter
ruff check src/ tests/

# Run type checker
mypy src/

# Run tests locally
labctl test
```

## Project structure

```
builder/
├── install.sh              # Setup script for nixos-control
├── pyproject.toml          # Project configuration
├── README.md               # This file
├── src/
│   └── labctl/
│       ├── __init__.py
│       ├── cli.py          # Command-line interface
│       ├── config.py       # Configuration (TOML + env vars)
│       ├── ssh.py          # SSH client and tunnel
│       ├── deployer.py     # Repo deployment
│       ├── provisioner.py  # Lab provisioning
│       └── client.py       # HTTP client for lab services
└── tests/
    ├── conftest.py         # Pytest fixtures
    ├── common/             # Tests for all profiles
    └── lab1/               # Tests for lab1 profile
```

## NixOS configuration

The `hosts/builder-vm.nix` configuration provides:
- Python 3.11 with pip
- SSH client, git, rsync, curl
- Passwordless sudo for wheel group
