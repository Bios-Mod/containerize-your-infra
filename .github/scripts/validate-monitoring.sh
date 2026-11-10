#!/usr/bin/env bash
# Deploy to:   GitHub Actions runner / local workstation
# Apply:       .github/scripts/validate-monitoring.sh <module|stack <compose-file>>
# Module:      monitoring
# Requires:    git, jq, docker (compose plugin); yq v4 (mikefarah) or mikefarah/yq:4 container image
#
# Validates static consistency across monitoring configs, Compose bind mounts, and Grafana provisioning.
# Parameters modified from baseline: none

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
ROOT_REAL="$(cd "$ROOT" && pwd -P)"

MOD_REL="modules/monitoring/docker"
PROM_REL="$MOD_REL/configs/prometheus/prometheus.yml"
BLACKBOX_REL="$MOD_REL/configs/blackbox/blackbox.yml"
DS_DIR_REL="$MOD_REL/configs/grafana/provisioning/datasources"
DASH_PROV_DIR_REL="$MOD_REL/configs/grafana/provisioning/dashboards"
DASHBOARD_REL="$MOD_REL/configs/grafana/dashboards/lab-overview.json"
MOD_PROD_COMPOSE_REL="$MOD_REL/docker-compose.prod.yml"

export GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-ci-check}"

err() {
  echo "::error::$*" >&2
  exit 1
}

run_yq() {
  if command -v yq >/dev/null 2>&1 \
    && yq --version 2>/dev/null | grep -qi 'mikefarah' \
    && yq --version 2>/dev/null | grep -qE '(^|[[:space:]]|version )v?4\.'; then
    (cd "$ROOT_REAL" && yq "$@" </dev/null)
  else
    docker run --rm -i -v "$ROOT_REAL":/w -w /w mikefarah/yq:4 "$@" </dev/null
  fi
}

extract_host() {
  local raw="$1"
  local host="${raw#http://}"
  host="${host#https://}"
  host="${host%%/*}"
  host="${host%%:*}"
  printf '%s\n' "$host"
}

validate_module() {
  local -a yaml_files=("$PROM_REL" "$BLACKBOX_REL")
  local f rel_path
  local -a ds_files=()
  local -a dash_prov_files=()

  shopt -s nullglob
  for f in "$ROOT_REAL/$DS_DIR_REL"/*.yml "$ROOT_REAL/$DS_DIR_REL"/*.yaml; do
    rel_path="${f#"$ROOT_REAL/"}"
    ds_files+=("$rel_path")
    yaml_files+=("$rel_path")
  done
  for f in "$ROOT_REAL/$DASH_PROV_DIR_REL"/*.yml "$ROOT_REAL/$DASH_PROV_DIR_REL"/*.yaml; do
    rel_path="${f#"$ROOT_REAL/"}"
    dash_prov_files+=("$rel_path")
    yaml_files+=("$rel_path")
  done
  shopt -u nullglob

  if [ "${#ds_files[@]}" -eq 0 ]; then
    err "No Grafana datasource provisioning YAML files found under $DS_DIR_REL"
  fi
  if [ "${#dash_prov_files[@]}" -eq 0 ]; then
    err "No Grafana dashboard provisioning YAML files found under $DASH_PROV_DIR_REL"
  fi

  # 1. YAML syntax across Prometheus, Blackbox Exporter, and Grafana provisioning configs
  for rel_path in "${yaml_files[@]}"; do
    [ -f "$ROOT_REAL/$rel_path" ] || err "Missing expected YAML file: $rel_path"
    if ! run_yq '.' "$rel_path" >/dev/null; then
      err "Invalid YAML syntax in $rel_path"
    fi
  done

  # 2. Every Prometheus scrape params.module entry must exist under .modules in blackbox.yml
  local prom_json bb_json bb_modules prom_mods job mod
  prom_json="$(run_yq -o=json '.' "$PROM_REL")"
  bb_json="$(run_yq -o=json '.' "$BLACKBOX_REL")"
  bb_modules="$(jq -r '.modules // {} | keys[]' <<< "$bb_json")"

  prom_mods="$(jq -r '
    .scrape_configs[]?
    | .job_name as $job
    | (.params.module // [])
    | (if type == "array" then .[] else . end)
    | "\($job)\t\(.)"
  ' <<< "$prom_json")"

  while IFS=$'\t' read -r job mod; do
    [ -z "$mod" ] && continue
    if ! grep -Fqx "$mod" <<< "$bb_modules"; then
      err "Prometheus job '$job' references blackbox module '$mod', which is missing from .modules in $BLACKBOX_REL"
    fi
  done <<< "$prom_mods"

  # 3. Grafana dashboard metadata and datasource UID cross-check
  [ -f "$ROOT_REAL/$DASHBOARD_REL" ] || err "Missing Grafana dashboard file: $DASHBOARD_REL"
  if ! jq -e '.' "$ROOT_REAL/$DASHBOARD_REL" >/dev/null; then
    err "Invalid JSON syntax in $DASHBOARD_REL"
  fi

  local dash_uid dash_title
  dash_uid="$(jq -r '.uid // ""' "$ROOT_REAL/$DASHBOARD_REL")"
  dash_title="$(jq -r '.title // ""' "$ROOT_REAL/$DASHBOARD_REL")"
  [ -n "${dash_uid//[[:space:]]/}" ] || err "Dashboard $DASHBOARD_REL has an empty or missing uid"
  [ -n "${dash_title//[[:space:]]/}" ] || err "Dashboard $DASHBOARD_REL has an empty or missing title"

  local ds_json provisioned_uids=""
  for rel_path in "${ds_files[@]}"; do
    ds_json="$(run_yq -o=json '.' "$rel_path")"
    provisioned_uids+="$(jq -r '.datasources[]?.uid // empty' <<< "$ds_json")"$'\n'
  done

  local referenced_uids ref_uid
  referenced_uids="$(jq -r '
    [.. | objects | select(has("datasource")) | .datasource | select(type == "object") | .uid? // empty]
    | unique
    | .[]
  ' "$ROOT_REAL/$DASHBOARD_REL")"

  if [ -z "$referenced_uids" ]; then
    echo "::notice::Dashboard $DASHBOARD_REL references no datasource UIDs; skipping datasource UID cross-check"
  else
    while IFS= read -r ref_uid; do
      [ -z "$ref_uid" ] && continue
      if ! grep -Fqx "$ref_uid" <<< "$provisioned_uids"; then
        err "Dashboard $DASHBOARD_REL references datasource uid '$ref_uid', which is not provisioned under $DS_DIR_REL"
      fi
    done <<< "$referenced_uids"
  fi

  # 4. Module prod Compose bind mounts under configs/ must exist on disk
  local mod_dir_real="$ROOT_REAL/$MOD_REL"
  [ -f "$ROOT_REAL/$MOD_PROD_COMPOSE_REL" ] || err "Missing module compose file: $MOD_PROD_COMPOSE_REL"

  local compose_json bind_sources src
  compose_json="$(cd "$mod_dir_real" && docker compose -f docker-compose.prod.yml config --format json)"
  bind_sources="$(jq -r '.services[]?.volumes[]? | select(.type == "bind") | .source // empty' <<< "$compose_json")"

  while IFS= read -r src; do
    [ -z "$src" ] && continue
    case "$src" in
      "$mod_dir_real/configs/"*|"$ROOT/$MOD_REL/configs/"*|configs/*|./configs/*)
        (cd "$mod_dir_real" && [ -e "$src" ]) || err "Bind mount source does not exist: $src (in $MOD_PROD_COMPOSE_REL)"
        ;;
    esac
  done <<< "$bind_sources"

  echo "OK: monitoring module checks passed"
}

validate_stack() {
  local compose_arg="${1:-}"
  [ -n "$compose_arg" ] || err "Usage: $0 stack <compose-file>"

  local compose_path
  if [ -f "$compose_arg" ]; then
    compose_path="$compose_arg"
  elif [ -f "$ROOT_REAL/$compose_arg" ]; then
    compose_path="$ROOT_REAL/$compose_arg"
  else
    err "Compose file not found: $compose_arg"
  fi

  local compose_dir_real compose_base compose_json
  compose_dir_real="$(cd "$(dirname "$compose_path")" && pwd -P)"
  compose_base="$(basename "$compose_path")"
  compose_json="$(cd "$compose_dir_real" && docker compose -f "$compose_base" config --format json)"

  # 1. Every Prometheus target host (non-localhost) and relabel_configs replacement matches a service or container_name
  [ -f "$ROOT_REAL/$PROM_REL" ] || err "Missing Prometheus config: $PROM_REL"
  local prom_json allowed_hosts target_entries repl_entries job val host
  prom_json="$(run_yq -o=json '.' "$PROM_REL")"
  allowed_hosts="$(jq -r '.services // {} | to_entries[] | .key, (.value.container_name // empty)' <<< "$compose_json" | sort -u)"

  target_entries="$(jq -r '
    .scrape_configs[]?
    | .job_name as $job
    | .static_configs[]?.targets[]?
    | "\($job)\t\(.)"
  ' <<< "$prom_json")"

  while IFS=$'\t' read -r job val; do
    [ -z "$val" ] && continue
    host="$(extract_host "$val")"
    [ "$host" = "localhost" ] && continue
    if ! grep -Fqx "$host" <<< "$allowed_hosts"; then
      err "Prometheus job '$job' target '$val' resolves to host '$host', which matches no service or container_name in $compose_arg"
    fi
  done <<< "$target_entries"

  repl_entries="$(jq -r '
    .scrape_configs[]?
    | .job_name as $job
    | .relabel_configs[]?
    | select(.replacement? != null and .replacement != "")
    | "\($job)\t\(.replacement)"
  ' <<< "$prom_json")"

  while IFS=$'\t' read -r job val; do
    [ -z "$val" ] && continue
    host="$(extract_host "$val")"
    [ "$host" = "localhost" ] && continue
    if ! grep -Fqx "$host" <<< "$allowed_hosts"; then
      err "Prometheus job '$job' relabel replacement '$val' resolves to host '$host', which matches no service or container_name in $compose_arg"
    fi
  done <<< "$repl_entries"

  # 2. All stack bind mounts under modules/ exist, excluding host-generated unversioned keys/certs
  local bind_sources src
  bind_sources="$(jq -r '.services[]?.volumes[]? | select(.type == "bind") | .source // empty' <<< "$compose_json")"

  while IFS= read -r src; do
    [ -z "$src" ] && continue
    case "$src" in
      "$ROOT_REAL/modules/"*|"$ROOT/modules/"*|modules/*)
        case "$src" in
          */configs/ssh/*|*/configs/keys/*|*/traefik/certs*)
            continue
            ;;
        esac
        (cd "$compose_dir_real" && [ -e "$src" ]) || err "Bind mount source does not exist: $src (in $compose_arg)"
        ;;
    esac
  done <<< "$bind_sources"

  echo "OK: monitoring stack checks passed ($compose_base)"
}

case "${1:-}" in
  module)
    [ "$#" -eq 1 ] || err "Usage: $0 module"
    validate_module
    ;;
  stack)
    [ "$#" -eq 2 ] || err "Usage: $0 stack <compose-file>"
    validate_stack "$2"
    ;;
  *)
    err "Usage: $0 <module|stack <compose-file>>"
    ;;
esac
