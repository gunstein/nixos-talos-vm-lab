SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# Canonical deploy tree - all lab commands run from here
ROOT := /etc/nixos/talos-host

# Select which lab profile to operate on (lab1, lab2, ...)
LAB ?= lab1

# Override if you don't want sudo (e.g. inside a root shell)
SUDO ?= sudo

# Use these if you want to run fmt/lint through the Nix devshell
NIX ?= nix
DEV := $(NIX) develop -c

.PHONY: help doctor doctor-nok8s fmt lint fmt-nix lint-nix \
        lab-all lab-wipe lab-provision lab-verify demo demo-only \
        k8s-nodes k8s-pods

help:
	@echo "Targets (LAB defaults to lab1, override with LAB=lab2):"
	@echo ""
	@echo "  make doctor            - host/profile health checks (read-only)"
	@echo "  make doctor-nok8s       - doctor, skip kubernetes checks"
	@echo ""
	@echo "  make fmt               - format bash scripts (shfmt)"
	@echo "  make lint              - lint bash scripts (shellcheck)"
	@echo "  make fmt-nix           - run fmt via nix develop"
	@echo "  make lint-nix          - run lint via nix develop"
	@echo ""
	@echo "  make lab-all           - create/boot/provision/verify (calls: ./scripts/lab $(LAB) all)"
	@echo "  make lab-wipe          - destroy lab VMs/net (calls: ./scripts/lab $(LAB) wipe)"
	@echo "  make lab-provision     - (calls: ./scripts/lab $(LAB) provision)"
	@echo "  make lab-verify        - (calls: ./scripts/lab $(LAB) verify)"
	@echo ""
	@echo "  make demo              - build, deploy and expose the demo (./scripts/lab $(LAB) demo)"
	@echo "  make demo-db           - demo with CloudNativePG database (./scripts/lab $(LAB) demo-db)"
	@echo "  make monitoring        - deploy Prometheus + Grafana (./scripts/lab $(LAB) monitoring)"
	@echo "  make ingress           - deploy Traefik Ingress Controller (./scripts/lab $(LAB) ingress)"
	@echo ""
	@echo "Convenience kubectl (requires kubeconfig already present):"
	@echo "  make k8s-nodes         - kubectl get nodes"
	@echo "  make k8s-pods          - kubectl get pods -A"
	@echo ""
	@echo "Examples:"
	@echo "  make lab-all                 # uses lab1 (default)"
	@echo "  make lab-all LAB=lab2        # uses lab2"
	@echo "  make demo-db LAB=lab2        # demo with database on lab2"

doctor:
	./scripts/doctor $(LAB)

doctor-nok8s:
	./scripts/doctor $(LAB) --no-k8s

fmt:
	./scripts/fmt

lint:
	./scripts/lint

fmt-nix:
	$(DEV) ./scripts/fmt

lint-nix:
	$(DEV) ./scripts/lint

lab-all:
	cd $(ROOT) && $(SUDO) ./scripts/lab $(LAB) all

lab-wipe:
	cd $(ROOT) && $(SUDO) ./scripts/lab $(LAB) wipe

lab-provision:
	cd $(ROOT) && $(SUDO) ./scripts/lab $(LAB) provision

lab-verify:
	cd $(ROOT) && $(SUDO) ./scripts/lab $(LAB) verify

demo:
	cd $(ROOT) && $(SUDO) ./scripts/lab $(LAB) demo

demo-db:
	cd $(ROOT) && $(SUDO) ./scripts/lab $(LAB) demo-db

monitoring:
	cd $(ROOT) && $(SUDO) ./scripts/lab $(LAB) monitoring

ingress:
	cd $(ROOT) && $(SUDO) ./scripts/lab $(LAB) ingress

# Aliases (keep your existing naming in scripts; make just provides shortcuts)
demo-only: demo

k8s-nodes:
	kubectl get nodes

k8s-pods:
	kubectl get pods -A
