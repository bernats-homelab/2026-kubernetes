# Loki / Writes (mixin compilado): Loki roda como binário único.
include "_lib";
drop_vars(["namespace"])
| single_binary("loki")
| on_exprs(
    gsub("cluster_job_route:loki_request_duration_seconds_(?<s>[a-z]+):sum_rate\\{(?<m>[^}]*)\\}";
         "sum by (cluster, job, route) (rate(loki_request_duration_seconds_\(.s){\(.m)}[$__rate_interval]))"))
