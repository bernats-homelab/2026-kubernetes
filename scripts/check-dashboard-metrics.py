#!/usr/bin/env python3
"""Lista, por dashboard, as métricas usadas nas queries que o Prometheus não tem.

Uso manual (não roda no CI: lá não há NAS, Tailscale nem dados do Immich):
  scripts/check-dashboard-metrics.py DIR_OU_JSON... --names nomes.txt
  scripts/check-dashboard-metrics.py DIR_OU_JSON... --prometheus http://localhost:9090
Rode também a cada upgrade do coletor: os nomes OTel mudam entre versões.
"""
import argparse
import json
import pathlib
import re
import sys
import urllib.request

KEYWORDS = {
    "by", "without", "on", "ignoring", "group_left", "group_right", "and", "or",
    "unless", "bool", "offset", "inf", "nan", "le",
}
STRING = re.compile(r"\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'")
BRACES = re.compile(r"\{[^{}]*\}")
RANGE = re.compile(r"\[[^\]]*\]")
VARS = re.compile(r"\$\{[^}]*\}|\$\w+|\[\[\w+\]\]")
GROUPING = re.compile(r"\b(by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)")
LABEL_VALUES = re.compile(r"^label_values\((.*),\s*[\w$]+\)\s*$", re.S)
QUERY_RESULT = re.compile(r"^query_result\((.*)\)\s*$", re.S)
IDENT = re.compile(r"[a-zA-Z_:][a-zA-Z0-9_:]*")
NAME_MATCH = re.compile(r"__name__\s*=~?\s*\"([^\"]+)\"")


def exprs(node):
    """Percorre o JSON e devolve as expressões PromQL (targets e variáveis)."""
    if isinstance(node, dict):
        for key, val in node.items():
            if key == "expr" and isinstance(val, str):
                yield val
            elif key == "query" and isinstance(val, str):
                m = LABEL_VALUES.match(val) or QUERY_RESULT.match(val)
                if m:
                    yield m.group(1)
            else:
                yield from exprs(val)
    elif isinstance(node, list):
        for item in node:
            yield from exprs(item)


def metrics(expr):
    patterns = NAME_MATCH.findall(expr)
    text = STRING.sub('""', expr)
    text = RANGE.sub("", text)
    text = VARS.sub("", text)
    while BRACES.search(text):
        text = BRACES.sub("", text)
    text = GROUPING.sub("", text)
    found = set()
    for m in IDENT.finditer(text):
        word, end = m.group(0), m.end()
        if word in KEYWORDS or text[end:].lstrip().startswith("("):
            continue
        if "_" in word or word == "up":
            found.add(word)
    return found, patterns


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--names")
    ap.add_argument("--prometheus")
    args = ap.parse_args()
    if args.names:
        have = set(pathlib.Path(args.names).read_text(encoding="utf-8").split())
    elif args.prometheus:
        url = args.prometheus.rstrip("/") + "/api/v1/label/__name__/values"
        have = set(json.load(urllib.request.urlopen(url))["data"])
    else:
        ap.error("informe --names ou --prometheus")
    files = []
    for p in map(pathlib.Path, args.paths):
        files += sorted(p.rglob("*.json")) if p.is_dir() else [p]
    missing_total = 0
    for f in files:
        dash = json.loads(f.read_text(encoding="utf-8"))
        miss, regex_miss = set(), set()
        for e in exprs(dash):
            found, patterns = metrics(e)
            miss |= {m for m in found if m not in have}
            for pat in patterns:
                if not any(re.fullmatch(pat, n) for n in have):
                    regex_miss.add(pat)
        miss |= {f"__name__=~{p}" for p in regex_miss}
        missing_total += len(miss)
        print(f"{f.name}: {'ok' if not miss else str(len(miss)) + ' faltando'}")
        for m in sorted(miss):
            print(f"    {m}")
    return 1 if missing_total else 0


if __name__ == "__main__":
    sys.exit(main())
