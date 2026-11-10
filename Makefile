# Rode no WSL (máquina de controle). O CI chama os mesmos targets.
SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

# Em /mnt/c o Ansible ignora ansible.cfg do cwd (diretório world-writable); ANSIBLE_CONFIG resolve.
export ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg
export PATH := $(HOME)/.local/bin:$(PATH)

# ASK_BECOME_PASS=0 quando o sudo do notebook não pede senha (NOPASSWD).
ASK_BECOME_PASS ?= 1
BECOME_FLAGS := $(if $(filter 1,$(ASK_BECOME_PASS)),--ask-become-pass,)
PLAYBOOK := ansible-playbook $(BECOME_FLAGS)
INVENTORY := ansible/inventory/local.yaml

# OpenTofu (Storage Box da Hetzner): HCLOUD_TOKEN e TF_VAR_state_passphrase vêm do SOPS.
TOFU_DIR := infra/hetzner
TOFU := sops exec-env $(TOFU_DIR)/secrets.sops.yaml

.PHONY: help deps lint test-unit test-render test check-inventory plan apply idempotency kubeconfig reset \
	tofu-plan tofu-apply backup-secret

help: ## Lista os targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

deps: ## Instala as ferramentas da máquina de controle (versões fixadas)
	./scripts/setup-control-node.sh

lint: ## Todos os hooks do pre-commit em todos os arquivos
	pre-commit run --all-files

test-unit: ## helm lint + helm unittest do chart app-of-apps
	helm lint --strict kubernetes/apps
	helm unittest kubernetes/apps

test-render: ## Renderiza manifests do repo e charts upstream e valida com kubeconform/kube-linter
	./scripts/validate-manifests.sh local
	./scripts/validate-manifests.sh upstream

test: lint test-unit test-render ## Tudo que roda sem cluster

check-inventory:
	@test -f $(INVENTORY) || { echo "Crie $(INVENTORY) a partir de ansible/inventory/inventory.example.yaml"; exit 1; }

plan: check-inventory ## Dry-run (--check --diff) contra o notebook
	cd ansible && $(PLAYBOOK) site.yaml --check --diff

apply: check-inventory lint ## Aplica no notebook (roda lint antes)
	cd ansible && $(PLAYBOOK) site.yaml

idempotency: check-inventory ## Reaplica e falha se algo mudar
	cd ansible && ../scripts/assert-idempotent.sh site.yaml $(BECOME_FLAGS)

kubeconfig: check-inventory ## Atualiza ~/.kube/notebook.yaml
	cd ansible && $(PLAYBOOK) site.yaml --tags kubeconfig

reset: check-inventory ## Remove o k3s do notebook (pede confirmação)
	cd ansible && $(PLAYBOOK) reset.yaml

tofu-plan: ## OpenTofu: mostra o que muda no Storage Box da Hetzner
	$(TOFU) 'tofu -chdir=$(TOFU_DIR) init -input=false -lockfile=readonly >/dev/null && tofu -chdir=$(TOFU_DIR) plan -input=false'

tofu-apply: ## OpenTofu: aplica no Storage Box (cobra na conta Hetzner; pede confirmação)
	$(TOFU) 'tofu -chdir=$(TOFU_DIR) init -input=false -lockfile=readonly >/dev/null && tofu -chdir=$(TOFU_DIR) apply -input=false'

backup-secret: ## Preenche o repositório e o known_hosts do restic a partir do state do OpenTofu
	$(TOFU) ./scripts/backup-fill-secret.sh
