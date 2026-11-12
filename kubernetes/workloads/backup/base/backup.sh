#!/bin/sh
# Backup off-site do NAS (ADR 011). Roda na imagem restic/restic (Alpine, busybox sh).
#   /config  RESTIC_REPOSITORY, RESTIC_PASSWORD e, em produção, id_ed25519 + known_hosts
#   /source  o que vai para o backup (raiz do SSD do NAS, NFS read-only)
#   /cache   cache do restic (índices e árvores; acelera o incremental)
# Cada etapa loga uma linha JSON {"message_type":"homelab",...}; o `restic backup`
# loga o próprio summary. Os alertas (observability/base/alerts/backup.yaml) leem
# essas linhas no Loki.
set -eu

export RESTIC_REPOSITORY_FILE=/config/RESTIC_REPOSITORY
export RESTIC_PASSWORD_FILE=/config/RESTIC_PASSWORD
export RESTIC_CACHE_DIR=/cache

log() { printf '{"message_type":"homelab","step":"%s","msg":"%s"}\n' "$1" "$2"; }

# SFTP para o Storage Box (porta 23 no RESTIC_REPOSITORY). O ssh recusa chave
# legível por outros, então a cópia vai para o HOME (emptyDir) com 0600.
if [ -f /config/id_ed25519 ]; then
  mkdir -p "${HOME}/.ssh"
  cp /config/id_ed25519 "${HOME}/.ssh/id_ed25519"
  chmod 600 "${HOME}/.ssh/id_ed25519"
  set -- -o "sftp.args=-i ${HOME}/.ssh/id_ed25519 -o UserKnownHostsFile=/config/known_hosts -o StrictHostKeyChecking=yes -o ServerAliveInterval=60"
fi

if ! restic "$@" cat config >/dev/null 2>&1; then
  log init "repositório não encontrado; criando"
  restic "$@" init
fi

# Locks de execuções mortas (activeDeadlineSeconds no meio do envio inicial).
restic "$@" unlock

log backup "início"
status=0
restic "$@" backup /source --host nas --tag nas --exclude-caches --json --quiet || status=$?
case "${status}" in
  0) log backup "ok" ;;
  # 3 = snapshot criado, mas algum arquivo não pôde ser lido: segue para a retenção
  # e falha o Job no final para aparecer no alerta.
  3) log backup "snapshot incompleto: arquivos ilegíveis (veja os erros acima)" ;;
  *)
    log backup "falhou com código ${status}"
    exit "${status}"
    ;;
esac

# Retenção: 7 diários, 4 semanais, 6 mensais. O prune (reescrita de pacotes) só
# aos domingos, junto com a verificação de 5% dos dados.
log forget "início"
if [ "$(date +%u)" = "7" ]; then
  restic "$@" forget --host nas --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
  log check "início"
  restic "$@" check --read-data-subset=5%
  log check "ok"
else
  restic "$@" forget --host nas --keep-daily 7 --keep-weekly 4 --keep-monthly 6
fi
log forget "ok"

log fim "backup terminou com código ${status}"
exit "${status}"
