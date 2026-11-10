# Lidos por scripts/backup-fill-secret.sh para montar o RESTIC_REPOSITORY do cluster.
# Sensíveis para não aparecerem em logs: o usuário e o FQDN identificam a conta.
output "storage_box_username" {
  value     = hcloud_storage_box.nas_offsite.username
  sensitive = true
}

output "storage_box_server" {
  value     = hcloud_storage_box.nas_offsite.server
  sensitive = true
}

output "storage_box_password" {
  value     = random_password.storage_box.result
  sensitive = true
}
