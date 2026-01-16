# Demo stack (frontend + backend)

What you get:
- Namespace `demo`
- A tiny `nginx` **frontend** Deployment serving a static HTML page
- A tiny **backend** (Go HTTP server) reachable as `/api/hello` (proxied by the frontend)
- Traefik Ingress routing via `demo.lab.local`

How it works in this repo:
- The backend image is built on the **NixOS-host VM** using Podman and pushed to a small **local registry** running on the NixOS-host (`services.dockerRegistry`, port `5000`).
- The backend source is in `apps/demo-backend/` (Go + Dockerfile).
- Talos nodes pull the backend image via the libvirt gateway IP for the lab network (usually `${TALOS_GATEWAY}:5000`).
- The `demo` command builds the backend, renders the manifest with the correct registry address, and applies it.

Notes:
- In a single-node Talos cluster, the only node is often tainted as `control-plane:NoSchedule`.
  The `demo` command automatically removes that taint so the demo can schedule.
- Pods run as non-root (compatible with Pod Security "restricted").

Access the demo via Traefik Ingress:

- `https://demo.lab.local/`
- `https://demo.lab.local/api/hello`

Architecture:

```
Browser → NixOS-host:443 → socat proxy → Traefik (hostNetwork) → demo-frontend
```


## Demo with database (`demo-db`)

Use `./scripts/lab lab1 demo-db` to deploy with CloudNativePG PostgreSQL.

Additional endpoints when database is enabled:
- `GET /api/items` - List all items
- `POST /api/items` - Create item (body: `{"name": "..."}`)

The database cluster (`demo-db`) is created in the `demo` namespace. CloudNativePG automatically creates a Secret (`demo-db-app`) with the connection URI.

Files specific to database mode:
- `51-backend-deployment-db.yaml` - Backend with `DATABASE_URL` env var
- `65-database-cluster.yaml` - CloudNativePG Cluster resource
