#!/usr/bin/env python3
"""Classify every routed app into the 4 route classes and validate auth posture.

Reliable replacement for validate-external-routes.sh. Unlike the old script it:
  * resolves each route's exposure by its parent Gateway's CLASS
    (envoy -> internal tier, envoy-external -> internet tier), not by name guesswork
  * sees bjw-s app-template routes embedded in HelmRelease .spec.values.route
    (rendered name = "<release>-<routeKey>"), which the old grep missed entirely
  * reports the 4 classes and fails if an internet-facing route has no auth posture

Route classes (see docs/architecture/routing.md):
  1. internal-only              parents all on internal-tier class
  2. internal+external (auth)   both tiers, external route uses gateway default auth
  3. internal+external (public) both tiers, external route has a public opt-out
  4. external-only              parents all on internet-tier class

Static analysis of kubernetes/apps — no cluster needed. Exit 1 on any violation.
"""
from __future__ import annotations
import sys, pathlib, yaml

REPO = pathlib.Path(__file__).resolve().parents[3]
APPS = REPO / "kubernetes" / "apps"
ENVOY = REPO / "kubernetes/apps/network/envoy-gateway/app/envoy.yaml"

# GatewayClass names that are the internet boundary (auth-by-default).
EXTERNAL_CLASSES = {"envoy-external"}

G, Y, R, N = "\033[0;32m", "\033[1;33m", "\033[0;31m", "\033[0m"


def load_docs(p: pathlib.Path):
    try:
        return [d for d in yaml.safe_load_all(p.read_text()) if isinstance(d, dict)]
    except Exception:
        return []


def gateway_classes() -> dict[str, str]:
    """Map Gateway name -> gatewayClassName from the envoy manifest."""
    m = {}
    for d in load_docs(ENVOY):
        if d.get("kind") == "Gateway":
            m[d["metadata"]["name"]] = d.get("spec", {}).get("gatewayClassName")
    return m


def app_dirs():
    """App build dirs = kustomization.yaml alongside a helmrelease or httproute."""
    for kz in APPS.rglob("kustomization.yaml"):
        d = kz.parent
        if (d / "helmrelease.yaml").exists() or list(d.glob("httproute*.yaml")):
            yield d


def render(d: pathlib.Path):
    """kubectl kustomize a dir (applies components + replacements). [] on failure."""
    import subprocess
    try:
        out = subprocess.run(["kubectl", "kustomize", str(d)], capture_output=True,
                             text=True, timeout=60)
        if out.returncode != 0:
            print(f"{Y}warn:{N} kustomize failed for {d.relative_to(REPO)}: "
                  f"{out.stderr.strip().splitlines()[-1] if out.stderr else '?'}", file=sys.stderr)
            return []
        return [x for x in yaml.safe_load_all(out.stdout) if isinstance(x, dict)]
    except Exception as e:
        print(f"{Y}warn:{N} render error {d}: {e}", file=sys.stderr)
        return []


def collect():
    routes = []          # (name, ns, [parent names], [hosts], source)
    public_targets = {}  # HTTPRoute name -> source (SecurityPolicy opt-out = empty extAuth)
    for d in app_dirs():
        src = str(d.relative_to(REPO))
        for doc in render(d):
            kind = doc.get("kind")
            if kind == "HTTPRoute":
                spec = doc.get("spec", {})
                routes.append((
                    doc["metadata"]["name"], doc["metadata"].get("namespace"),
                    [r.get("name") for r in spec.get("parentRefs", [])],
                    spec.get("hostnames", []), src,
                ))
            elif kind == "HelmRelease":
                rel = doc["metadata"]["name"]
                route_val = (doc.get("spec", {}).get("values", {}) or {}).get("route", {})
                if isinstance(route_val, dict):
                    for key, rt in route_val.items():
                        if not isinstance(rt, dict):
                            continue
                        routes.append((
                            f"{rel}-{key}", doc["metadata"].get("namespace"),
                            [r.get("name") for r in rt.get("parentRefs", [])],
                            rt.get("hostnames", []), f"{src} (values.route.{key})",
                        ))
            elif kind == "SecurityPolicy":
                spec = doc.get("spec", {})
                for tref in spec.get("targetRefs", []):
                    if tref.get("kind") == "HTTPRoute" and tref.get("name"):
                        # empty/absent extAuth => opt-out (public); present => forward-auth
                        if not spec.get("extAuth"):
                            public_targets[tref["name"]] = src
    return routes, public_targets


def main() -> int:
    gclass = gateway_classes()
    routes, public = collect()

    # Group by hostname (the 4 classes are per-app/hostname, not per-route).
    # A host with both an internal-tier and an internet-tier route is "dual".
    hosts_map = {}  # hostname -> {int, ext, public, names[]}
    violations = []
    for name, ns, parents, hosts, src in routes:
        is_ext = bool({gclass.get(pn) for pn in parents} & EXTERNAL_CLASSES)
        is_int = any(gclass.get(pn) is not None and gclass.get(pn) not in EXTERNAL_CLASSES
                     for pn in parents)
        if not (is_ext or is_int):
            violations.append(f"{ns}/{name}: parentRefs {parents} resolve to no known Gateway class ({src})")
            continue
        for h in hosts or []:
            if not h or "{{" in h:      # skip empty / unrendered-template hostnames
                continue
            e = hosts_map.setdefault(h, {"int": False, "ext": False, "public": False, "names": []})
            e["int"] |= is_int
            e["ext"] |= is_ext
            e["public"] |= is_ext and (name in public)
            e["names"].append(f"{ns}/{name}")

    buckets = {"internal-only": [], "dual-auth": [], "dual-public": [], "external-only": []}
    for h, e in hosts_map.items():
        if e["ext"] and e["int"]:
            b = "dual-public" if e["public"] else "dual-auth"
        elif e["ext"]:
            b = "external-only"
        else:
            b = "internal-only"
        posture = "public-optout" if e["public"] else ("default-auth" if e["ext"] else "none(LAN)")
        buckets[b].append((h, posture, ", ".join(sorted(set(e["names"])))))

    order = [("internal-only", "1. internal-only (default)"),
             ("dual-auth", "2. internal+external — Authentik auth"),
             ("dual-public", "3. internal+external — PUBLIC opt-out"),
             ("external-only", "4. external-only")]
    for key, title in order:
        rows = sorted(buckets[key])
        print(f"\n{title}  ({len(rows)})")
        for h, posture, names in rows:
            tag = f"{Y}[{posture}]{N}" if "public" in posture else f"{G}[{posture}]{N}"
            print(f"  {tag} {h:34s} {names}")

    ext_total = len(buckets["dual-auth"]) + len(buckets["dual-public"]) + len(buckets["external-only"])
    print(f"\n---\nExternal-facing routes: {ext_total} "
          f"({len(buckets['dual-public'])} public opt-out, "
          f"{len(buckets['dual-auth']) + len(buckets['external-only'])} Authentik-default)")

    if violations:
        print(f"\n{R}❌ posture violations:{N}")
        for v in violations:
            print(f"  - {v}")
        return 1
    print(f"\n{G}✅ every external-facing route resolves to a known auth posture{N}")
    if buckets["dual-public"]:
        print(f"{Y}Public routes bypass Authentik — confirm each is intentional (authentication.md).{N}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
