#!/usr/bin/env bash
# dns-split-check.sh — proves the split-DNS "prefer internal" invariant is live.
#
# Runs from a machine ON the LAN. Queries the in-cluster resolver (k8s-gateway)
# and asserts, per route class:
#
#   internal-only          -> resolves to the INTERNAL gateway IP only
#   internal+external (dual)-> resolves to the INTERNAL gateway IP ONLY
#                              (this is the invariant the GatewayClass split fixes;
#                               before the fix it returned BOTH .53 and .54)
#   external-only          -> does NOT resolve to the internal gateway IP
#                              (falls through to public DNS -> Cloudflare Tunnel)
#
# Usage:
#   RESOLVER=10.0.3.52 INTERNAL_IP=10.0.3.53 EXTERNAL_IP=10.0.3.54 \
#     DUAL_HOSTS="hass requests auth" \
#     INTERNAL_HOSTS="git grafana shlink" \
#     EXTERNAL_HOSTS="s echo" \
#     DOMAIN=example.com scripts/tests/dns-split-check.sh
#
# All hostnames are <sub>.$DOMAIN. Requires `dig`.
set -euo pipefail

RESOLVER="${RESOLVER:-10.0.3.52}"
INTERNAL_IP="${INTERNAL_IP:-10.0.3.53}"
EXTERNAL_IP="${EXTERNAL_IP:-10.0.3.54}"
DOMAIN="${DOMAIN:?set DOMAIN (e.g. DOMAIN=example.com)}"
DUAL_HOSTS="${DUAL_HOSTS:-}"
INTERNAL_HOSTS="${INTERNAL_HOSTS:-}"
EXTERNAL_HOSTS="${EXTERNAL_HOSTS:-}"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
fail=0

resolve() { dig +short +time=3 +tries=1 "@${RESOLVER}" "${1}.${DOMAIN}" A | sort | paste -sd' ' -; }
has_ip()  { grep -qw "$2" <<<"$1"; }

echo "== resolver ${RESOLVER} | internal ${INTERNAL_IP} | external ${EXTERNAL_IP} | domain ${DOMAIN} =="
echo

echo "-- internal-only: expect ${INTERNAL_IP}, NOT ${EXTERNAL_IP} --"
for h in $INTERNAL_HOSTS; do
  a="$(resolve "$h")"
  if has_ip "$a" "$INTERNAL_IP" && ! has_ip "$a" "$EXTERNAL_IP"; then
    echo -e "${GREEN}PASS${NC} $h -> $a"
  else echo -e "${RED}FAIL${NC} $h -> ${a:-<empty>}"; fail=1; fi
done

echo
echo "-- dual (internal+external): expect ${INTERNAL_IP} ONLY (the prefer-internal invariant) --"
for h in $DUAL_HOSTS; do
  a="$(resolve "$h")"
  if has_ip "$a" "$INTERNAL_IP" && ! has_ip "$a" "$EXTERNAL_IP"; then
    echo -e "${GREEN}PASS${NC} $h -> $a"
  else echo -e "${RED}FAIL${NC} $h -> ${a:-<empty>}  (must be ${INTERNAL_IP} only)"; fail=1; fi
done

echo
echo "-- external-only: must NOT return ${INTERNAL_IP} (falls through to public) --"
for h in $EXTERNAL_HOSTS; do
  a="$(resolve "$h")"
  if ! has_ip "$a" "$INTERNAL_IP"; then
    echo -e "${GREEN}PASS${NC} $h -> ${a:-<public/fallthrough>}"
  else echo -e "${RED}FAIL${NC} $h -> $a  (should not resolve to internal gateway)"; fail=1; fi
done

echo
[[ $fail -eq 0 ]] && echo -e "${GREEN}✅ split-DNS invariant holds${NC}" || { echo -e "${RED}❌ split-DNS invariant violated${NC}"; exit 1; }
