#!/usr/bin/env python3
"""Valida as regras de alerta do Grafana versionadas em base/alerts/*.yaml.

Confere o que o provisionamento só reclama em runtime (e que o e2e demora a mostrar):
uid único em todos os arquivos, severity conhecida (a política de notificação roteia
por ela), datasource conhecido e o par A (query) + B (threshold) esperado.
"""
import pathlib
import sys

import yaml

ALERTS = pathlib.Path(__file__).resolve().parent.parent / "kubernetes/workloads/observability/base/alerts"
SEVERITIES = {"critical", "warning", "info"}
DATASOURCES = {"prometheus", "loki"}
NODATA = {"OK", "Alerting", "NoData"}


def main():
    errors, uids, total = [], {}, 0
    for path in sorted(ALERTS.glob("*.yaml")):
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        for group in doc.get("groups", []):
            for rule in group.get("rules", []):
                total += 1
                uid = rule.get("uid", "?")
                where = f"{path.name}:{uid}"
                if uid in uids:
                    errors.append(f"{where}: uid repetido (já em {uids[uid]})")
                uids[uid] = path.name
                if rule.get("labels", {}).get("severity") not in SEVERITIES:
                    errors.append(f"{where}: severity deve ser {sorted(SEVERITIES)}")
                if rule.get("noDataState") not in NODATA:
                    errors.append(f"{where}: noDataState inválido")
                data = {d["refId"]: d for d in rule.get("data", [])}
                a, b = data.get("A"), data.get("B")
                if rule.get("condition") != "B" or not a or not b:
                    errors.append(f"{where}: esperado condition B com queries A e B")
                    continue
                if a["datasourceUid"] not in DATASOURCES:
                    errors.append(f"{where}: datasourceUid {a['datasourceUid']} desconhecido")
                if not a["model"].get("expr"):
                    errors.append(f"{where}: A sem expr")
                if b["datasourceUid"] != "__expr__" or b["model"].get("type") != "threshold":
                    errors.append(f"{where}: B deve ser um threshold em __expr__")
    for err in errors:
        print(err, file=sys.stderr)
    print(f"{total} regras em {len(list(ALERTS.glob('*.yaml')))} arquivos: {'ERROS' if errors else 'ok'}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
