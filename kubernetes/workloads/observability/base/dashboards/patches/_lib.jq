# Funções compartilhadas pelos patches (jq -L .../patches; include "_lib";).

# Aplica f às queries PromQL/LogQL do dashboard: expr dos painéis e as queries
# das variáveis de template (query como string ou como objeto, e definition).
def on_exprs(f):
  walk(
    if type == "object" then
      (if (.expr? | type) == "string" then .expr |= f else . end)
      | (if (.definition? | type) == "string" then .definition |= f else . end)
      | (if (.query? | type) == "string" then .query |= f
         elif (.query? | type) == "object" and (.query.query? | type) == "string" then .query.query |= f
         else . end)
    else . end);

# Remove variáveis de template pelo nome.
def drop_vars($names):
  .templating.list |= map(select(.name as $n | ($names | index($n)) == null));

# Remove painéis (exceto rows) cujas queries casam com o regex: usam métricas que o
# nosso stack, só com OTel nativo, não tem (kube-state-metrics, cAdvisor etc.).
def drop_panels($re):
  walk(
    if type == "object" and (.panels? | type) == "array" then
      .panels |= map(select(
        .type == "row"
        or (((.targets // []) | map(.expr? // "") | any(test($re))) | not)))
    else . end);

# Mixins do Loki/Tempo assumem microsserviços ("$namespace/<componente>"): aqui
# cada backend é um único binário, e o job vem de service.namespace/service.name.
def single_binary($name):
  on_exprs(
    gsub("job=~?\"(\\(\\$namespace\\)|\\$namespace)/[^\"]*\""; "job=~\"(.+/)?" + $name + "\"")
    | gsub(", *namespace=~?\"\\$namespace\""; "")
    | gsub("namespace=~?\"\\$namespace\", *"; ""));
