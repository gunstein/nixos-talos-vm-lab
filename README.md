# Talos Kubernetes Lab on NixOS

Dette repoet setter opp en **lokal Kubernetes-lab basert på Talos Linux**, kjørt i **libvirt/KVM** på en **NixOS host**.

Fokus:
- enkel og forutsigbar flyt
- én lab aktiv om gangen (lab1, lab2, …)
- idempotente kommandoer
- tydelig skille mellom deploy og lab-operasjoner

---

## Oversikt

**Roller:**

- `install.sh`  
  → deployer repoet til `/etc/nixos/talos-host`  
  → kjører ev. `nixos-rebuild switch`  
  → starter ikke laber

- `scripts/lab`  
  → eneste entrypoint for lab-operasjoner  
  → kjører alltid som root  
  → wrapper rundt `scripts/lab.sh`

- `scripts/lab.sh`  
  → faktisk orkestrering (libvirt, Talos, Kubernetes)

---

## Katalogstruktur (relevant)

```text
.
├── assets/
│   └── metal-amd64.iso
├── profiles/
│   ├── lab1/
│   │   ├── vars.env
│   │   └── nodes.csv
│   └── lab2/
│       ├── vars.env
│       └── nodes.csv
├── scripts/
│   ├── install.sh
│   ├── lab
│   ├── lab.sh
│   ├── lib.sh
│   ├── common.sh
│   ├── talos-provision.sh
│   └── talos-verify.sh
└── README.md
```

---

## 1. Førstegangs deploy (eller etter endringer i repo)

Kjøres fra repo-klonen (f.eks. `~/nixos-talos-vm-lab`):

```bash
sudo ./scripts/install.sh
```

Dette gjør:
- rsync av repo → `/etc/nixos/talos-host`
- sikrer `hardware-configuration.nix`
- sikrer Talos ISO i deploy-treet
- kjører `nixos-rebuild switch` (kan slås av med `NO_REBUILD=1`)

Etter dette jobber du kun fra:

```bash
cd /etc/nixos/talos-host
```

---

## 2. Kjøre en lab (standard flyt)

### Starte lab1

```bash
sudo ./scripts/lab lab1 all
```

Dette gjør i rekkefølge:
1. setter opp libvirt-nett (idempotent)
2. oppretter / starter VM-er
3. provisionerer Talos
4. bootstrapper Kubernetes
5. skriver kubeconfig
6. verifiserer cluster

Når den er ferdig:

```bash
kubectl get nodes
```

---

## 3. Bytte mellom laber (én lab av gangen)

Dette repoet er ment brukt slik:
> Kun én lab er aktiv om gangen

### Bytte fra lab1 → lab2

```bash
sudo ./scripts/lab lab1 wipe
sudo ./scripts/lab lab2 all
```

### Bytte fra lab2 → lab1

```bash
sudo ./scripts/lab lab2 wipe
sudo ./scripts/lab lab1 all
```

---

## 4. Kommandoer

```bash
sudo ./scripts/lab <lab> <cmd>
```

| Kommando | Beskrivelse |
|--------|-------------|
| status | Vis status |
| up | Opprett nett + VM |
| provision | Talos bootstrap |
| verify | Verifiser cluster |
| all | up → provision → verify |
| wipe | Fjern lab |
| net-recreate | Tving nett-recreate |

---

## 5. Kubeconfig

Etter `lab <name> all` fungerer:

```bash
kubectl get nodes
```

Kubeconfig skrives til:
- `/root/.kube/talos-<lab>.config`
- `/home/<user>/.kube/config`

---

## Status

Stabil Talos Kubernetes-lab klar for videre testing.