"""Command-line interface for labctl."""

import argparse
import logging
import sys
from pathlib import Path

from labctl.config import LabConfig, RepoConfig
from labctl.deployer import Deployer
from labctl.provisioner import Provisioner
from labctl.ssh import SSHClient

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)


def cmd_deploy(args: argparse.Namespace, lab_config: LabConfig) -> int:
    """Deploy repository to nixos-host."""
    if args.local:
        local_path = Path(args.local)
        repo_config = RepoConfig.from_versions_env(local_path)
    else:
        repo_config = RepoConfig()

    with SSHClient(lab_config) as ssh:
        deployer = Deployer(lab_config, repo_config, ssh)

        if args.local:
            deployer.full_deploy(Path(args.local))
        else:
            deployer.full_deploy()

    return 0


def cmd_provision(args: argparse.Namespace, lab_config: LabConfig) -> int:
    """Provision the lab."""
    with SSHClient(lab_config) as ssh:
        provisioner = Provisioner(lab_config, ssh)

        if args.command == "all":
            provisioner.all()
        elif args.command == "up":
            provisioner.up()
        elif args.command == "wipe":
            provisioner.wipe()
        elif args.command == "status":
            print(provisioner.status())
        elif args.command == "doctor":
            print(provisioner.doctor())

    return 0


def cmd_test(args: argparse.Namespace, lab_config: LabConfig) -> int:
    """Run tests against the lab."""
    import os
    import subprocess

    # Pass config to tests via environment
    env = os.environ.copy()
    env["NIXOS_HOST"] = lab_config.nixos_host
    env["NIXOS_USER"] = lab_config.nixos_user
    env["LAB_PROFILE"] = lab_config.profile
    env["TUNNEL_PORT"] = str(lab_config.tunnel_local_port)

    pytest_args = ["pytest", "-v"]

    if args.smoke:
        pytest_args.extend(["-m", "smoke"])
    if args.pattern:
        pytest_args.extend(["-k", args.pattern])

    pytest_args.append("tests/")

    result = subprocess.run(pytest_args, env=env)
    return result.returncode


def main() -> int:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Talos lab provisioning and testing tool",
        epilog="Environment variables: NIXOS_HOST, NIXOS_USER, LAB_PROFILE, TUNNEL_PORT, SSH_KEY_PATH",
    )
    parser.add_argument(
        "--host",
        help="nixos-host hostname or IP (env: NIXOS_HOST)",
    )
    parser.add_argument(
        "--user",
        help="SSH username (env: NIXOS_USER)",
    )
    parser.add_argument(
        "--profile",
        help="Lab profile (env: LAB_PROFILE)",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Verbose output",
    )

    subparsers = parser.add_subparsers(dest="action", required=True)

    # deploy command
    deploy_parser = subparsers.add_parser("deploy", help="Deploy repo to nixos-host")
    deploy_parser.add_argument(
        "--local",
        help="Use local repo path instead of cloning",
    )

    # provision command
    provision_parser = subparsers.add_parser("provision", help="Provision the lab")
    provision_parser.add_argument(
        "command",
        choices=["all", "up", "wipe", "status", "doctor"],
        help="Lab command to run",
    )

    # test command
    test_parser = subparsers.add_parser("test", help="Run tests")
    test_parser.add_argument(
        "--smoke",
        action="store_true",
        help="Run only smoke tests",
    )
    test_parser.add_argument(
        "-k",
        "--pattern",
        help="Only run tests matching pattern",
    )

    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    # Build config from env vars, with CLI flags as overrides
    lab_config = LabConfig.from_env(
        nixos_host=args.host,
        nixos_user=args.user,
        profile=args.profile,
    )

    try:
        if args.action == "deploy":
            return cmd_deploy(args, lab_config)
        elif args.action == "provision":
            return cmd_provision(args, lab_config)
        elif args.action == "test":
            return cmd_test(args, lab_config)
    except Exception as e:
        logger.error(f"Error: {e}")
        if args.verbose:
            raise
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
