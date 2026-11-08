# ArgoCD (argo-cd examples/dashboard.json): o job vem como service.namespace/nome
# quando o alvo é descoberto por pod, e o namespace do seletor usava kube_pod_info.
include "_lib";
on_exprs(
  gsub("job=\"(?<j>argocd-[a-z-]+)\""; "job=~\"(.+/)?" + .j + "\"")
  | gsub("label_values\\(kube_pod_info, *namespace\\)"; "label_values(argocd_app_info, namespace)"))
