#!/usr/bin/env python3
"""Substituto do KSOPS para validação offline (pre-commit e CI, sem chave age).

Recebe o ResourceList do kustomize (exec KRM function), lê cada arquivo de
`files` do generator e devolve o recurso com os valores trocados por um
placeholder. Valida estrutura (kubeconform/kube-linter), nunca os valores.
Falha se algum arquivo não estiver criptografado pelo SOPS.
"""

import base64
import sys

import yaml

PLACEHOLDER = "ksops-stub"


def stub_values(values, encode):
    placeholder = base64.b64encode(PLACEHOLDER.encode()).decode() if encode else PLACEHOLDER
    return {key: placeholder for key in (values or {})}


def main():
    resource_list = yaml.safe_load(sys.stdin)
    items = list(resource_list.get("items") or [])
    for path in resource_list["functionConfig"].get("files", []):
        with open(path, encoding="utf-8") as handle:
            doc = yaml.safe_load(handle)
        if not isinstance(doc, dict) or "sops" not in doc:
            sys.exit(f"ksops-stub: {path} não está criptografado pelo SOPS")
        del doc["sops"]
        if "data" in doc:
            doc["data"] = stub_values(doc["data"], encode=True)
        if "stringData" in doc:
            doc["stringData"] = stub_values(doc["stringData"], encode=False)
        items.append(doc)
    resource_list["items"] = items
    yaml.safe_dump(resource_list, sys.stdout, sort_keys=False)


if __name__ == "__main__":
    main()
