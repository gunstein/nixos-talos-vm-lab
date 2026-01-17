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

### On builder-vm

1. Install Python 3.11+ and dependencies:

```bash
# NixOS
nix-shell -p python311 python311Packages.pip

# Or using pip
pip install -e ".[dev]"
```

2. Configure SSH access to nixos-host:

```bash
# Generate SSH key if needed
ssh-keygen -t ed25519

# Copy to nixos-host
ssh-copy-id gunstein@nixos-host
```

3. Test connection:

```bash
ssh gunstein@nixos-host "echo 'Connection OK'"
```

## Usage

### Deploy and provision

```bash
# Full workflow: clone, download ISO, deploy, install, provision
labctl deploy
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

## Development

```bash
# Install dev dependencies
pip install -e ".[dev]"

# Run linter
ruff check src/ tests/

# Run type checker
mypy src/

# Run tests locally (requires nixos-host access)
pytest -v tests/
```

## Project structure

```
builder/
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
