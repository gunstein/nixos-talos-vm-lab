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


def cmd_deploy(args: argparse.Namespace) -> int:
    """Deploy repository to nixos-host."""
    lab_config = LabConfig(
        nixos_host=args.host,
        nixos_user=args.user,
        profile=args.profile,
    )
    repo_config = RepoConfig()

    with SSHClient(lab_config) as ssh:
        deployer = Deployer(lab_config, repo_config, ssh)

        if args.local:
            deployer.full_deploy(Path(args.local))
        else:
            deployer.full_deploy()

    return 0


def cmd_provision(args: argparse.Namespace) -> int:
    """Provision the lab."""
    lab_config = LabConfig(
        nixos_host=args.host,
        nixos_user=args.user,
        profile=args.profile,
    )

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


def cmd_test(args: argparse.Namespace) -> int:
    """Run tests against the lab."""
    import subprocess

    pytest_args = ["pytest", "-v"]

    if args.smoke:
        pytest_args.extend(["-m", "smoke"])
    if args.pattern:
        pytest_args.extend(["-k", args.pattern])

    pytest_args.append("tests/")

    result = subprocess.run(pytest_args)
    return result.returncode


def main() -> int:
    """Main entry point."""
    parser = argparse.ArgumentParser(description="Talos lab provisioning and testing tool")
    parser.add_argument(
        "--host",
        default="nixos-host",
        help="nixos-host hostname or IP",
    )
    parser.add_argument(
        "--user",
        default="gunstein",
        help="SSH username",
    )
    parser.add_argument(
        "--profile",
        default="lab1",
        help="Lab profile (lab1, lab2, ...)",
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

    try:
        if args.action == "deploy":
            return cmd_deploy(args)
        elif args.action == "provision":
            return cmd_provision(args)
        elif args.action == "test":
            return cmd_test(args)
    except Exception as e:
        logger.error(f"Error: {e}")
        if args.verbose:
            raise
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
