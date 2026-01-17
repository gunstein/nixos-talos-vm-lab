"""SSH utilities for connecting to nixos-host."""

import logging
import socket
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

import paramiko

from labctl.config import LabConfig

logger = logging.getLogger(__name__)


@dataclass
class CommandResult:
    """Result of a remote command execution."""

    exit_code: int
    stdout: str
    stderr: str

    @property
    def success(self) -> bool:
        return self.exit_code == 0


class SSHClient:
    """SSH client for connecting to nixos-host."""

    def __init__(self, config: LabConfig) -> None:
        self.config = config
        self._client: paramiko.SSHClient | None = None

    def connect(self) -> None:
        """Establish SSH connection."""
        if self._client is not None:
            return

        self._client = paramiko.SSHClient()
        self._client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

        connect_kwargs: dict = {
            "hostname": self.config.nixos_host,
            "port": self.config.nixos_port,
            "username": self.config.nixos_user,
        }

        if self.config.ssh_key_path:
            connect_kwargs["key_filename"] = str(self.config.ssh_key_path)
        else:
            # Use SSH agent
            connect_kwargs["allow_agent"] = True

        logger.info(f"Connecting to {self.config.nixos_user}@{self.config.nixos_host}")
        self._client.connect(**connect_kwargs)
        logger.info("Connected")

    def disconnect(self) -> None:
        """Close SSH connection."""
        if self._client:
            self._client.close()
            self._client = None
            logger.info("Disconnected")

    def run(self, command: str, timeout: int | None = None) -> CommandResult:
        """Execute a command on nixos-host."""
        if self._client is None:
            raise RuntimeError("Not connected")

        timeout = timeout or self.config.command_timeout
        logger.debug(f"Running: {command}")

        stdin, stdout, stderr = self._client.exec_command(command, timeout=timeout)
        exit_code = stdout.channel.recv_exit_status()

        result = CommandResult(
            exit_code=exit_code,
            stdout=stdout.read().decode(),
            stderr=stderr.read().decode(),
        )

        if result.success:
            logger.debug(f"Command succeeded (exit={exit_code})")
        else:
            logger.warning(f"Command failed (exit={exit_code}): {result.stderr}")

        return result

    def run_sudo(self, command: str, timeout: int | None = None) -> CommandResult:
        """Execute a command with sudo on nixos-host."""
        return self.run(f"sudo {command}", timeout=timeout)

    def upload_file(self, local_path: Path, remote_path: Path) -> None:
        """Upload a file via SFTP."""
        if self._client is None:
            raise RuntimeError("Not connected")

        sftp = self._client.open_sftp()
        try:
            logger.info(f"Uploading {local_path} -> {remote_path}")
            sftp.put(str(local_path), str(remote_path))
        finally:
            sftp.close()

    def upload_directory(self, local_path: Path, remote_path: Path) -> None:
        """Upload a directory recursively via SFTP."""
        if self._client is None:
            raise RuntimeError("Not connected")

        sftp = self._client.open_sftp()
        try:
            self._upload_dir_recursive(sftp, local_path, remote_path)
        finally:
            sftp.close()

    def _upload_dir_recursive(
        self, sftp: paramiko.SFTPClient, local_path: Path, remote_path: Path
    ) -> None:
        """Recursively upload directory contents."""
        # Create remote directory if it doesn't exist
        try:
            sftp.stat(str(remote_path))
        except FileNotFoundError:
            logger.debug(f"Creating remote directory: {remote_path}")
            sftp.mkdir(str(remote_path))

        for item in local_path.iterdir():
            remote_item = remote_path / item.name

            if item.is_dir():
                if item.name == ".git":
                    continue  # Skip .git directory
                self._upload_dir_recursive(sftp, item, remote_item)
            else:
                logger.debug(f"Uploading {item} -> {remote_item}")
                sftp.put(str(item), str(remote_item))

    def __enter__(self) -> "SSHClient":
        self.connect()
        return self

    def __exit__(self, *args: object) -> None:
        self.disconnect()


class SSHTunnel:
    """SSH tunnel for accessing lab services."""

    def __init__(
        self,
        client: SSHClient,
        local_port: int,
        remote_port: int,
        remote_host: str = "127.0.0.1",
    ) -> None:
        self.client = client
        self.local_port = local_port
        self.remote_port = remote_port
        self.remote_host = remote_host
        self._server_socket: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._running = False

    def start(self) -> None:
        """Start the SSH tunnel."""
        if self.client._client is None:
            raise RuntimeError("SSH client not connected")

        self._running = True
        self._server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server_socket.bind(("127.0.0.1", self.local_port))
        self._server_socket.listen(5)
        self._server_socket.settimeout(1.0)

        self._thread = threading.Thread(target=self._tunnel_loop, daemon=True)
        self._thread.start()

        logger.info(
            f"SSH tunnel started: localhost:{self.local_port} -> {self.remote_host}:{self.remote_port}"
        )

    def stop(self) -> None:
        """Stop the SSH tunnel."""
        self._running = False
        if self._server_socket:
            self._server_socket.close()
            self._server_socket = None
        if self._thread:
            self._thread.join(timeout=2.0)
            self._thread = None
        logger.info("SSH tunnel stopped")

    def _tunnel_loop(self) -> None:
        """Main tunnel loop accepting connections."""
        transport = self.client._client.get_transport()  # type: ignore
        if transport is None:
            return

        while self._running:
            try:
                client_socket, addr = self._server_socket.accept()  # type: ignore
            except socket.timeout:
                continue
            except OSError:
                break

            # Open channel to remote
            try:
                channel = transport.open_channel(
                    "direct-tcpip",
                    (self.remote_host, self.remote_port),
                    addr,
                )
            except Exception as e:
                logger.error(f"Failed to open channel: {e}")
                client_socket.close()
                continue

            # Forward data in both directions
            threading.Thread(
                target=self._forward_data,
                args=(client_socket, channel),
                daemon=True,
            ).start()

    def _forward_data(self, client_socket: socket.socket, channel: paramiko.Channel) -> None:
        """Forward data between client socket and SSH channel."""
        try:
            while True:
                # Check both directions
                r_ready = []
                if channel.recv_ready():
                    data = channel.recv(4096)
                    if not data:
                        break
                    client_socket.sendall(data)

                try:
                    client_socket.setblocking(False)
                    data = client_socket.recv(4096)
                    client_socket.setblocking(True)
                    if not data:
                        break
                    channel.sendall(data)
                except BlockingIOError:
                    client_socket.setblocking(True)

                time.sleep(0.01)
        except Exception:
            pass
        finally:
            channel.close()
            client_socket.close()

    def __enter__(self) -> "SSHTunnel":
        self.start()
        return self

    def __exit__(self, *args: object) -> None:
        self.stop()


@contextmanager
def ssh_connection(config: LabConfig) -> Iterator[SSHClient]:
    """Context manager for SSH connection."""
    client = SSHClient(config)
    try:
        client.connect()
        yield client
    finally:
        client.disconnect()


@contextmanager
def ssh_tunnel(
    client: SSHClient,
    local_port: int,
    remote_port: int = 443,
) -> Iterator[SSHTunnel]:
    """Context manager for SSH tunnel."""
    tunnel = SSHTunnel(client, local_port, remote_port)
    try:
        tunnel.start()
        yield tunnel
    finally:
        tunnel.stop()
