# Cópia off-site do NAS: Storage Box da Hetzner (ADR 011). Rode só pela WSL:
# `make tofu-plan` / `make tofu-apply` (o token e a passphrase vêm de secrets.sops.yaml).
terraform {
  required_version = "~> 1.13.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "1.70.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
  }
}

# Token em HCLOUD_TOKEN (exportado pelo Makefile a partir do SOPS).
provider "hcloud" {}
