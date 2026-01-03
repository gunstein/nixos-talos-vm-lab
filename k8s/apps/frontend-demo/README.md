# Frontend demo (super simple)

What you get:
- Namespace `demo`
- A tiny `nginx` Deployment serving a static HTML page
- A `NodePort` Service on port `30080`

Inside the Talos lab network, the page is reachable at:

- `http://<any-node-ip>:30080/`

In this repository we typically forward it outward:

LAN → Ubuntu → NixOS-host VM (8080) → Talos node (30080)
