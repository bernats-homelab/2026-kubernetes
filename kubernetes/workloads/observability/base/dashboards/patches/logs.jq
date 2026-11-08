# Logs / App v2 (grafana.com 24866): feito para logs do Promtail (label job, JSON).
# Aqui os logs chegam por OTLP: service_name e detected_level (sem parse de JSON).
include "_lib";
.templating.list |= map(
  if .name == "level" then .query.label = "detected_level" else . end)
| on_exprs(
    gsub("label_values\\(job\\)"; "label_values(service_name)")
    | gsub("\\{job=~"; "{service_name=~")
    | gsub("\\| *json"; "")
    | gsub("\\| *level=~"; "| detected_level=~"))
