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


def confirm(message: str) -> bool:
    """Ask user for confirmation."""
    try:
        response = input(f"{message} [y/N] ").strip().lower()
        return response in ("y", "yes")
    except (EOFError, KeyboardInterrupt):
        print()
        return False


def cmd_deploy(args: argparse.Namespace, lab_config: LabConfig) -> int:
    """Deploy repository to nixos-host."""
    # Determine local repo path
    local_path = lab_config.local_repo
    if not local_path.exists():
        logger.error(f"Local repo not found: {local_path}")
        logger.error("Set local_repo in ~/.config/labctl/config.toml")
        return 1

    repo_config = RepoConfig.load(local_path)

    # Determine what to do
    install_only = args.install
    wipe_only = args.wipe
    provision_only = args.provision

    # Default: full deploy (wipe + install + provision)
    do_wipe = not install_only and not provision_only
    do_install = not wipe_only and not provision_only
    do_provision = not install_only and not wipe_only

    # Handle explicit flags
    if wipe_only:
        do_wipe = True
        do_install = False
        do_provision = False
    if install_only:
        do_wipe = False
        do_install = True
        do_provision = False
    if provision_only:
        do_wipe = False
        do_install = False
        do_provision = True

    # Confirmation for destructive operations
    if do_wipe and not args.yes:
        if not confirm("This will destroy the existing lab. Continue?"):
            logger.info("Aborted")
            return 0

    with SSHClient(lab_config) as ssh:
        if do_wipe:
            logger.info("Wiping existing lab...")
            provisioner = Provisioner(lab_config, ssh)
            provisioner.wipe()

        if do_install:
            logger.info("Deploying repo and running install.sh...")
            deployer = Deployer(lab_config, repo_config, ssh)
            deployer.full_deploy(local_path)

        if do_provision:
            logger.info("Provisioning lab...")
            provisioner = Provisioner(lab_config, ssh)
            provisioner.all()

    return 0


def cmd_status(args: argparse.Namespace, lab_config: LabConfig) -> int:
    """Show lab status."""
    with SSHClient(lab_config) as ssh:
        provisioner = Provisioner(lab_config, ssh)
        print(provisioner.status())
    return 0


def cmd_doctor(args: argparse.Namespace, lab_config: LabConfig) -> int:
    """Run health checks."""
    with SSHClient(lab_config) as ssh:
        provisioner = Provisioner(lab_config, ssh)
        print(provisioner.doctor())
    return 0


def cmd_test(args: argparse.Namespace, lab_config: LabConfig) -> int:
    """Run tests against the lab."""
    import os
    import subprocess
    import sys

    # Find tests directory (relative to this file or cwd)
    tests_base = Path(__file__).parent.parent.parent / "tests"
    if not tests_base.exists():
        tests_base = Path("tests")

    common_tests = tests_base / "common"
    profile_tests = tests_base / lab_config.profile

    # Pass config to tests via environment
    env = os.environ.copy()
    env["NIXOS_HOST"] = lab_config.nixos_host
    env["NIXOS_USER"] = lab_config.nixos_user
    env["LAB_PROFILE"] = lab_config.profile
    env["TUNNEL_PORT"] = str(lab_config.tunnel_local_port)

    # Use same Python interpreter as labctl to ensure pytest is available
    pytest_args = [sys.executable, "-m", "pytest", "-v"]

    if args.smoke:
        pytest_args.extend(["-m", "smoke"])
    if args.pattern:
        pytest_args.extend(["-k", args.pattern])

    # Add test directories: common + profile-specific
    if common_tests.exists():
        pytest_args.append(str(common_tests))
    if profile_tests.exists():
        pytest_args.append(str(profile_tests))
    else:
        logger.warning(f"No profile-specific tests found for '{lab_config.profile}'")

    if len(pytest_args) == 4:  # Only "python -m pytest -v", no test dirs
        logger.error("No test directories found")
        return 1

    logger.info(f"Running tests for profile: {lab_config.profile}")
    result = subprocess.run(pytest_args, env=env)
    return result.returncode


def cmd_config(args: argparse.Namespace, lab_config: LabConfig) -> int:
    """Show current configuration."""
    from labctl.config import _find_config_file

    config_file = _find_config_file()
    print(f"Config file: {config_file or '(none found)'}")
    print()
    print("[lab]")
    print(f"  profile = {lab_config.profile}")
    print(f"  local_repo = {lab_config.local_repo}")
    print()
    print("[nixos-host]")
    print(f"  host = {lab_config.nixos_host}")
    print(f"  user = {lab_config.nixos_user}")
    print(f"  port = {lab_config.nixos_port}")
    if lab_config.ssh_key_path:
        print(f"  ssh_key = {lab_config.ssh_key_path}")
    print()
    print("[tunnel]")
    print(f"  local_port = {lab_config.tunnel_local_port}")
    print(f"  remote_port = {lab_config.tunnel_remote_port}")

    return 0


def main() -> int:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Talos lab provisioning and testing tool",
        epilog="Config: ~/.config/labctl/config.toml",
    )
    parser.add_argument(
        "--host",
        help="nixos-host hostname or IP",
    )
    parser.add_argument(
        "--user",
        help="SSH username",
    )
    parser.add_argument(
        "--profile",
        help="Lab profile",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Verbose output",
    )

    subparsers = parser.add_subparsers(dest="action", required=True)

    # deploy command
    deploy_parser = subparsers.add_parser(
        "deploy",
        help="Deploy lab (default: wipe + install + provision)",
    )
    deploy_parser.add_argument(
        "--install",
        action="store_true",
        help="Only deploy repo and run install.sh (no wipe/provision)",
    )
    deploy_parser.add_argument(
        "--wipe",
        action="store_true",
        help="Only wipe the lab (no install/provision)",
    )
    deploy_parser.add_argument(
        "--provision",
        action="store_true",
        help="Only provision the lab (no wipe/install)",
    )
    deploy_parser.add_argument(
        "-y",
        "--yes",
        action="store_true",
        help="Skip confirmation prompt",
    )

    # status command
    subparsers.add_parser("status", help="Show lab status")

    # doctor command
    subparsers.add_parser("doctor", help="Run health checks")

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

    # config command
    subparsers.add_parser("config", help="Show current configuration")

    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    # Build config from file, env vars, and CLI flags
    lab_config = LabConfig.load(
        nixos_host=args.host,
        nixos_user=args.user,
        profile=args.profile,
    )

    try:
        if args.action == "deploy":
            return cmd_deploy(args, lab_config)
        elif args.action == "status":
            return cmd_status(args, lab_config)
        elif args.action == "doctor":
            return cmd_doctor(args, lab_config)
        elif args.action == "test":
            return cmd_test(args, lab_config)
        elif args.action == "config":
            return cmd_config(args, lab_config)
    except Exception as e:
        logger.error(f"Error: {e}")
        if args.verbose:
            raise
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
