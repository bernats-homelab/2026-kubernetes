# CloudNativePG (grafana.com 20417): sem kube-state-metrics, cAdvisor, volume stats
# (local-path não reporta) nem as métricas do controller-runtime do operador.
# Contadores chegam por OTLP com o sufixo _total.
include "_lib";
drop_vars(["operatorNamespace"])
| drop_panels("kubelet_volume_stats|controller_runtime|node_namespace|kube_pod_status_ready|kube_pod_info|kube_node_labels|kube_pod_container_resource_requests|kube_pod_spec_volumes")
| on_exprs(
    # kube_pod_container_status_ready -> k8s_container_ready, mantendo os labels
    # pod/namespace que as transformações do dashboard usam para juntar as tabelas.
    gsub("kube_pod_container_status_ready\\{container=\"postgres\",namespace=~\"\\$namespace\",pod=~\"\\$instances\"\\}";
         "label_replace(label_replace(k8s_container_ready{k8s_container_name=\"postgres\",k8s_namespace_name=~\"$namespace\",k8s_pod_name=~\"$instances\"}, \"pod\", \"$1\", \"k8s_pod_name\", \"(.*)\"), \"namespace\", \"$1\", \"k8s_namespace_name\", \"(.*)\")")
    | gsub("\\b(?<n>cnpg_pg_stat_(archiver_(archived|failed)_count|database_(blks_hit|blks_read|deadlocks|temp_bytes|tup_deleted|tup_fetched|tup_inserted|tup_returned|tup_updated|xact_commit|xact_rollback)))\\b"; "\(.n)_total")
    | gsub("(?<p>cnpg_pg_stat_\\(bgwriter_checkpoint\\|checkpointer\\)_(sync|write)_time)"; "\(.p)_total")
    | gsub("(?<p>cnpg_pg_stat_\\(bgwriter\\|checkpointer\\)_checkpoints_(req|timed))\\b"; "\(.p)_total"))
