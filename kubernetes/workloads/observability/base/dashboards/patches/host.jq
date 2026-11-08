# Host Metrics (grafana.com 24638): o seletor de host só oferecia k8s_node_name e
# host. Nossos hosts se distinguem por service.name (job) e host_name.
.templating.list |= map(
  if .name == "host_label" then
    .query = "job,host_name"
    | .current = {text: "job", value: "job"}
    | .options = [
        {selected: true, text: "job", value: "job"},
        {selected: false, text: "host_name", value: "host_name"}
      ]
  else . end)
