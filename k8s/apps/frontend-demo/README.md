# Demo stack (frontend + backend)

What you get:
- Namespace `demo`
- A tiny `nginx` **frontend** Deployment serving a static HTML page
- A tiny **backend** (Go HTTP server) reachable as `/api/hello` (proxied by the frontend)
- A `NodePort` Service on port `30080`

How it works in this repo:
- The backend image is built on the **NixOS-host VM** using Podman and pushed to a small **local registry** running on the NixOS-host (`services.dockerRegistry`, port `5000`).
- The backend source is in `apps/demo-backend/` (Go + Dockerfile).
- Talos nodes pull the backend image via the libvirt gateway IP for the lab network (usually `${TALOS_GATEWAY}:5000`).
- The `demo` command builds the backend, renders the manifest with the correct registry address, and applies it.

Notes:
- In a single-node Talos cluster, the only node is often tainted as `control-plane:NoSchedule`.
  The `demo` command automatically removes that taint so the demo can schedule.
- Pods run as non-root (compatible with Pod Security "restricted").

Inside the Talos lab network, the demo is reachable at:

- `http://<any-node-ip>:30080/`
- `http://<any-node-ip>:30080/api/hello`

In this repository we typically forward it outward:

LAN → Ubuntu → NixOS-host VM (8080) → Talos node (30080)
