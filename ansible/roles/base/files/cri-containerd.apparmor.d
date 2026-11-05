# Gerenciado pelo Ansible (2026-kubernetes), role base.
#
# Perfil AppArmor padrão dos containers (RuntimeDefault). É o template do
# containerd v2.3.4 (contrib/apparmor/template.go) renderizado como o containerd
# faria neste host (abi 3.0, tunables/global, abstractions/base, daemon
# unconfined), MAIS as duas regras marcadas com "stacked" abaixo.
#
# Por quê: com kernel.apparmor_restrict_unprivileged_unconfined=1 (Ubuntu 26.04,
# kernel 7.0.0-42+) o change_onexec do runc vira stacking e os processos do
# container ficam com o rótulo "cri-containerd.apparmor.d//&unconfined". O peer
# sem o sufixo não casa, e os sinais entre processos do mesmo container são
# negados: o Postgres (CNPG) trava na recuperação e lota as conexões.
#
# O containerd não gera o próprio perfil quando já existe um carregado com este
# nome, e o apparmor.service carrega este arquivo no boot, antes do k3s.
#
# Remover quando o k3s trouxer um containerd com a correção:
#   https://github.com/containerd/containerd/issues/14485
#   https://github.com/containerd/containerd/pull/14487 (usa //&*; aqui usamos
#   só o rótulo observado, //&unconfined)

abi <abi/3.0>,

#include <tunables/global>

profile cri-containerd.apparmor.d flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  network,
  capability,
  file,
  umount,
  # Host (privileged) processes may send signals to container processes.
  signal (receive) peer=unconfined,
  # runc may send signals to container processes.
  signal (receive) peer=runc,
  # crun may send signals to container processes.
  signal (receive) peer=crun,
  # Manager may send signals to container processes.
  signal (receive) peer=unconfined,
  # Container processes may send signals amongst themselves.
  signal (send,receive) peer=cri-containerd.apparmor.d,
  # stacked: mesmo peer com o rótulo empilhado (containerd#14485).
  signal (send,receive) peer="cri-containerd.apparmor.d//&unconfined",

  deny @{PROC}/* w,   # deny write for all files directly in /proc (not in a subdir)
  # deny write to files not in /proc/<number>/** or /proc/sys/**
  deny @{PROC}/{[^1-9/],[^1-9/][^0-9/],[^1-9s/][^0-9y/][^0-9s/],[^1-9/][^0-9/][^0-9/][^0-9/]*}/** w,
  deny @{PROC}/sys/[^k]** w,  # deny /proc/sys except /proc/sys/k* (effectively /proc/sys/kernel)
  deny @{PROC}/sys/kernel/{?,??,[^s][^h][^m]**} w,  # deny everything except shm* in /proc/sys/kernel/
  deny @{PROC}/sysrq-trigger rwklx,
  deny @{PROC}/kcore rwklx,

  deny mount,

  deny /sys/[^f]*/** wklx,
  deny /sys/f[^s]*/** wklx,
  deny /sys/fs/[^c]*/** wklx,
  deny /sys/fs/c[^g]*/** wklx,
  deny /sys/fs/cg[^r]*/** wklx,
  deny /sys/firmware/** rwklx,
  deny /sys/devices/virtual/powercap/** rwklx,
  deny /sys/kernel/security/** rwklx,

  # allow processes within the container to trace each other,
  # provided all other LSM and yama setting allow it.
  ptrace (trace,tracedby,read,readby) peer=cri-containerd.apparmor.d,
  # stacked: mesmo peer com o rótulo empilhado (containerd#14485).
  ptrace (trace,tracedby,read,readby) peer="cri-containerd.apparmor.d//&unconfined",
}
