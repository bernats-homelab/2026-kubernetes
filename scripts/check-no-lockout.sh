#!/usr/bin/env bash
# O notebook é acessado por SSH via Tailscale. Nenhuma task pode alterar o
# Tailscale, o servidor SSH, o firewall ou a rede do host — isso derrubaria o acesso.
# Linhas legítimas de leitura podem ser marcadas com o comentário `# lockout-safe`.
set -euo pipefail

readonly PATTERN='tailscale[[:space:]]+(up|down|logout|set|switch)|tailscaled|community\.general\.ufw|\bufw\b|iptables|nftables|\bnft\b|netplan|NetworkManager|nmcli|systemd-networkd|\bsshd\b|ssh\.service|ssh\.socket|authorized_key'

status=0
for file in "$@"; do
  if matches="$(grep -nEi "${PATTERN}" "${file}" | grep -v 'lockout-safe')"; then
    echo "ERRO: ${file} contém operação que pode derrubar o acesso ao notebook:" >&2
    echo "${matches}" >&2
    status=1
  fi
done
exit "${status}"
