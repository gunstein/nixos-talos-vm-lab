# Ubuntu: expose the demo frontend to your LAN

Your current setup is nested:

LAN → Ubuntu host → NixOS-host VM → Talos VM network

The NixOS-host VM runs a small forwarder on **port 8080** (created by `demo-frontend`).
This folder provides a tiny Ubuntu-side forwarder so that other machines on your LAN
can reach it via the Ubuntu host.

## 1) Find the NixOS-host VM IP (from Ubuntu)

If you use libvirt on Ubuntu, this often works:

```bash
sudo virsh domifaddr <vm-name>
```

Or check your libvirt DHCP leases.

## 2) Install + run the forwarder on Ubuntu

From this directory:

```bash
sudo ./install-frontend-forward.sh <NIXOS_HOST_VM_IP>
```

Default:
- Ubuntu listens on `:8080`
- Forwards to `<NIXOS_HOST_VM_IP>:8080`

Then your demo frontend should be reachable at:

- `http://<ubuntu-lan-ip>:8080/`
