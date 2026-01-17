# Builder VM - Lab Provisioning and Testing

This directory contains the Python tooling for automated lab provisioning and testing.
It's designed to run on a separate "builder" VM that controls the nixos-host remotely.

## Architecture

```
builder-vm (this code)
├── Clone repo from GitHub
├── Download Talos ISO
├── Deploy to nixos-host via SSH/rsync
├── Provision lab via SSH commands
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
3. Apply the NixOS configuration:

```bash
# Copy hardware-configuration.nix to hosts/
cp /etc/nixos/hardware-configuration.nix ~/nixos-talos-vm-lab/hosts/

# Build and switch
sudo nixos-rebuild switch --flake ~/nixos-talos-vm-lab#builder-vm
```

4. Run the install script:

```bash
cd ~/nixos-talos-vm-lab/builder
./install.sh
```

### Option 2: Existing system

1. Ensure Python 3.11+ and pip are installed
2. Run the install script:

```bash
cd ~/nixos-talos-vm-lab/builder
./install.sh
```

### Configure SSH access

```bash
# Generate SSH key if needed
ssh-keygen -t ed25519

# Copy to nixos-host
ssh-copy-id gunstein@<nixos-host-ip>

# Test connection
ssh gunstein@<nixos-host-ip> "echo 'Connection OK'"
```

### Set environment variables

Add to `~/.bashrc`:

```bash
export NIXOS_HOST=<nixos-host-ip>
export NIXOS_USER=gunstein
export LAB_PROFILE=lab1
```

## Usage

### Deploy and provision

```bash
# Full workflow: clone, download ISO, deploy, install, provision
labctl deploy
labctl provision all

# Using local repo (skip git clone)
labctl deploy --local ~/nixos-talos-vm-lab
labctl provision all

# Or step by step
labctl provision up       # Create VMs
labctl provision status   # Check status
labctl provision wipe     # Destroy lab
```

### Run tests

```bash
# All tests
labctl test

# Smoke tests only
labctl test --smoke

# Specific test pattern
labctl test -k "demo"
```

### Options

```bash
# Different host/user
labctl --host 192.168.1.100 --user myuser provision all

# Different lab profile
labctl --profile lab2 provision all

# Verbose output
labctl -v provision all
```

## Test categories

- **smoke** - Basic checks that the lab is functioning
  - Nodes ready
  - Core pods running
  - Demo endpoints responding
  - Monitoring stack up

- **resilience** - Recovery from failures
  - Pod deletion and recovery
  - Database data persistence

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NIXOS_HOST` | `nixos-host` | nixos-host hostname/IP |
| `NIXOS_USER` | `gunstein` | SSH username |
| `LAB_PROFILE` | `lab1` | Lab profile to use |
| `TUNNEL_PORT` | `8443` | Local port for SSH tunnel |
| `SSH_KEY_PATH` | (ssh-agent) | Path to SSH private key |

## Development

```bash
# Install with test and dev dependencies
pip install -e ".[test,dev]"

# Run linter
ruff check src/ tests/

# Run type checker
mypy src/

# Run tests (requires nixos-host access)
pytest -v tests/
```

## Project structure

```
builder/
├── install.sh              # Setup script
├── pyproject.toml          # Project configuration
├── README.md               # This file
├── src/
│   └── labctl/
│       ├── __init__.py
│       ├── cli.py          # Command-line interface
│       ├── config.py       # Configuration dataclasses
│       ├── ssh.py          # SSH client and tunnel
│       ├── deployer.py     # Repo deployment
│       ├── provisioner.py  # Lab provisioning
│       └── client.py       # HTTP client for lab services
└── tests/
    ├── __init__.py
    ├── conftest.py         # Pytest fixtures
    ├── test_smoke.py       # Smoke tests
    └── test_resilience.py  # Resilience tests
```

## NixOS configuration

The `hosts/builder-vm.nix` configuration provides:
- Python 3.11 with pip
- SSH client, git, rsync, curl
- Passwordless sudo for wheel group
