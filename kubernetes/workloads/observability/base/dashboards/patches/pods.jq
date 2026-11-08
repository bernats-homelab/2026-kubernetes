# Pods Metrics (grafana.com 20944): sem o label cluster (não promovemos
# k8s.cluster.name) e com os nomes atuais das métricas do kubeletstats
# (*_cpu_utilization_ratio foi substituída por *_cpu_usage, em núcleos).
include "_lib";
drop_vars(["cluster"])
| on_exprs(
    gsub(", *cluster=~?\"\\$cluster\""; "")
    | gsub("cluster=~?\"\\$cluster\", *"; "")
    | gsub("k8s_pod_cpu_utilization_ratio"; "k8s_pod_cpu_usage")
    | gsub("container_cpu_utilization_ratio"; "container_cpu_usage"))
