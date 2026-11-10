# Senha da conta principal: o restic usa só a chave SSH, mas a API exige uma senha.
# Fica apenas no state criptografado (`tofu output -raw storage_box_password`).
resource "random_password" "storage_box" {
  length           = 32
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "-_+="
}

resource "hcloud_storage_box" "nas_offsite" {
  name             = "nas-offsite"
  storage_box_type = "bx11"
  location         = "fsn1"
  password         = random_password.storage_box.result

  labels = {
    "managed-by" = "opentofu"
    "purpose"    = "nas-offsite-backup"
  }

  # Só SFTP/SSH (porta 23), acessível da internet de casa.
  access_settings = {
    reachable_externally = true
    ssh_enabled          = true
    samba_enabled        = false
    webdav_enabled       = false
    zfs_enabled          = false
  }

  # Snapshots do lado da Hetzner, fora do alcance da chave SSH do cluster: se o
  # repositório restic for apagado ou corrompido, volta-se até 7 dias. Rodam às
  # 07:00 UTC (04:00 em Brasília), antes do backup das 05:00, então guardam o estado
  # anterior ao prune do dia. Não custam à parte, mas ocupam a cota do box.
  snapshot_plan = {
    max_snapshots = 7
    hour          = 7
    minute        = 0
  }

  delete_protection = true

  # Chave pública do CronJob do restic; a privada está em
  # kubernetes/workloads/backup/overlays/nas/restic.sops.yaml.
  ssh_keys = [trimspace(file("${path.module}/restic_ed25519.pub"))]

  lifecycle {
    # A API não troca chaves SSH depois de criar: mudar ssh_keys recriaria o box
    # (apagando o backup). Para trocar a chave, edite .ssh/authorized_keys no box.
    ignore_changes  = [ssh_keys]
    prevent_destroy = true
  }
}
