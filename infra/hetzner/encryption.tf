# State e plan criptografados pelo próprio OpenTofu: o terraform.tfstate é versionado
# no git (tem a senha do Storage Box) e nunca existe em texto puro. A passphrase fica
# em secrets.sops.yaml, que só a chave da WSL abre. Sem ela não dá para ler o state.
variable "state_passphrase" {
  description = "Passphrase do state (TF_VAR_state_passphrase, exportada pelo Makefile)"
  type        = string
  sensitive   = true
}

terraform {
  encryption {
    key_provider "pbkdf2" "wsl" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "wsl" {
      keys = key_provider.pbkdf2.wsl
    }

    state {
      method   = method.aes_gcm.wsl
      enforced = true
    }

    plan {
      method   = method.aes_gcm.wsl
      enforced = true
    }
  }
}
