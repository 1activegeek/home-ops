#!/bin/sh
# Heartbeat runner: turns Kubernetes' own health checks into Healthchecks pings.
# Runs as the long-lived `heartbeat` controller (one replica, loop every 60s).
#
# Opt in by annotating a Deployment, StatefulSet or DaemonSet:
#   healthchecks.io/slug: sonarr                       (required)
#   healthchecks.io/url: http://sonarr.media.svc...    (optional deep check)
#   healthchecks.io/containers: "code-server=ha-code-server ..."
#                                    (optional; extra checks, one per sidecar)
#
# Each round, per annotated workload:
#   healthy   = at least one pod Ready (every pod for a DaemonSet) and, if set,
#               GET url answers 2xx straight at the Service (no Envoy/DNS/TLS;
#               that path is Gatus' job)
#   healthy   -> ping /<slug>               (resets the check's timer)
#   unhealthy -> ping /<slug>/log           (recorded, no alert) for the first
#                HEARTBEAT_FAIL_AFTER-1 rounds, so rollouts and Recreate
#                restarts don't page; then /<slug>/fail with the reason
#
# Each "<container>=<slug>" pair in healthchecks.io/containers gets its own
# check, healthy while that container is ready in at least one pod (every pod
# for a DaemonSet). For sidecars that a pod-level check can't name, e.g. an
# editor bound to loopback inside the Home Assistant pod.
#
# Dead-man's switch: a check only stays up while pings keep arriving. A deleted
# workload, a dead runner, or a dead cluster all mean silence, and Healthchecks
# alerts. Removing the annotation does NOT delete the check; delete it in the
# UI when retiring an app, or it will (correctly) go down.
#
# Scheduled jobs go to the separate "Jobs" project. Opt a CronJob in with
#   healthchecks.io/slug: db-backup-forgejo     (required)
#   healthchecks.io/grace: "3600"               (optional, seconds; default 1h)
# or, for CronJobs another controller generates (Longhorn recurring jobs),
# list them in HEARTBEAT_EXTRA_CRONJOBS as "<ns>/<cronjob>=<slug> ...".
# Each gets a cron-schedule check with the CronJob's own schedule. The runner
# watches the Jobs it spawns: /start when one begins, a ping when it completes,
# /fail with the reason when it fails. A run that never happens is silence, and
# Healthchecks alerts once the schedule plus grace has passed.
#
# The runner's own check (heartbeat-runner) has a shorter grace than the
# service checks, so if the runner dies its alert arrives first and explains
# why every service check is about to go down with it.
set -u

api="${HC_API_URL}"
ping="${api}/ping/${HC_PING_KEY}"
jobs_ping="${api}/ping/${HC_JOBS_PING_KEY:-}"
interval="${HEARTBEAT_INTERVAL:-60}"
fail_after="${HEARTBEAT_FAIL_AFTER:-5}"
state=/tmp/heartbeat
self=heartbeat-runner

mkdir -p "${state}/seen" "${state}/fails" "${state}/jobs" "${state}/jobs-seen"
touch "${state}/last-round"

log() { echo "heartbeat: $*"; }

# kubectl with a hard deadline. Not --request-timeout: with that flag set,
# kubectl 1.37 skips its in-cluster config and dials localhost:8080 instead.
k() { timeout 30 kubectl "$@"; }

# $1 = slug, $2 = tags, $3 = desc, $4 = timeout, $5 = grace
upsert() {
  body=$(jq -nc --arg s "$1" --arg t "$2" --arg d "$3" --argjson to "$4" --argjson gr "$5" \
    '{name: $s, slug: $s, tags: $t, desc: $d, timeout: $to, grace: $gr, channels: "*", unique: ["slug"]}')
  curl -fsS -m 10 -o /dev/null -X POST \
    -H "X-Api-Key: ${HC_API_KEY}" -H "Content-Type: application/json" \
    --data-raw "${body}" "${api}/api/v3/checks/"
}

# $1 = slug[/fail|/log], $2 = body (shown in the event log and the alert)
hc() {
  curl -fsS -m 10 --retry 2 -o /dev/null --data-raw "$2" "${ping}/$1"
}

# Why a workload's pods aren't Ready, e.g. " (sonarr-abc: CrashLoopBackOff)".
# $3 = container name: report only that container.
pod_states() {
  [ -n "$2" ] || return 0
  s=$(k get pods -n "$1" -l "$2" -o json 2>/dev/null | jq -r --arg c "${3:-}" '
    [.items[] | .metadata.name as $p
     | if (.status.containerStatuses // []) == [] then "\($p): \(.status.phase)"
       else (.status.containerStatuses[] | select(.ready | not)
             | select($c == "" or .name == $c)
             | "\($p): \(.state.waiting.reason // .state.terminated.reason // "not ready")")
       end] | unique | join("; ")')
  [ -n "${s}" ] && printf ' (%s)' "${s}"
}

# How many of a workload's pods have container $3 ready. Fails if it can't tell.
container_ready() {
  pods=$(k get pods -n "$1" -l "$2" -o json) || return 1
  printf '%s' "${pods}" | jq --arg c "$3" \
    '[.items[] | select(any(.status.containerStatuses[]?; .name == $c and .ready))] | length'
}

# $9 = container: check that container's readiness instead of the pod's.
check_one() {
  slug=$1 kind=$2 ns=$3 name=$4 url=$5 ready=$6 want=$7 selector=$8 container=${9:-}
  what="${kind} ${ns}/${name}${container:+ container ${container}}"

  case "${slug}" in
    "" | *[!a-z0-9_-]*)
      log "skipping ${what}: slug '${slug}' must be lowercase [a-z0-9_-]"
      return
      ;;
  esac

  if [ -n "${container}" ]; then
    desc="Heartbeat from the monitoring/healthchecks runner: container ${container} of ${kind} ${ns}/${name} is ready in a pod"
  else
    desc="Heartbeat from the monitoring/healthchecks runner: ${kind} ${ns}/${name} has a Ready pod"
  fi
  [ -n "${url}" ] && desc="${desc} and ${url} answers 2xx"
  desc="${desc}. Silence means the workload, the runner or the cluster is gone."
  if [ "$(cat "${state}/seen/${slug}" 2>/dev/null)" != "${desc}" ]; then
    if upsert "${slug}" "k8s ${ns}" "${desc}" 120 300; then
      printf '%s' "${desc}" >"${state}/seen/${slug}"
      log "registered check ${slug} (${what})"
    else
      log "API upsert of ${slug} failed; retrying next round"
      return
    fi
  fi

  reason=""
  if [ "${want}" -eq 0 ]; then
    reason="${kind} ${ns}/${name} is scaled to 0"
  elif { [ "${kind}" = DaemonSet ] && [ "${ready}" -lt "${want}" ]; } || [ "${ready}" -lt 1 ]; then
    reason="${what}: ${ready}/${want} pods Ready$(pod_states "${ns}" "${selector}" "${container}")"
  elif [ -n "${url}" ]; then
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "${url}")
    case "${code}" in
      2??) ;;
      000) reason="${what}: ${url} unreachable" ;;
      *) reason="${what}: ${url} returned HTTP ${code}" ;;
    esac
  fi

  if [ -z "${reason}" ]; then
    [ -f "${state}/fails/${slug}" ] && log "${slug} recovered"
    rm -f "${state}/fails/${slug}"
    target="${slug}"
    body="ok: ${ready}/${want} Ready${url:+, ${url} 2xx}"
  else
    n=$(($(cat "${state}/fails/${slug}" 2>/dev/null || echo 0) + 1))
    echo "${n}" >"${state}/fails/${slug}"
    log "${slug} unhealthy (${n}/${fail_after}): ${reason}"
    if [ "${n}" -ge "${fail_after}" ]; then
      target="${slug}/fail"
      body="${reason}"
    else
      target="${slug}/log"
      body="unhealthy ${n}/${fail_after}: ${reason}"
    fi
  fi

  # A 404 means the check was deleted in the UI; forget it so the next round
  # re-creates it instead of pinging into the void.
  hc "${target}" "${body}" || {
    log "ping ${slug} failed"
    rm -f "${state}/seen/${slug}"
  }
}

# --- Scheduled jobs (Jobs project) ------------------------------------------

# $1 = JSON check definition
upsert_job() {
  curl -fsS -m 10 -o /dev/null -X POST \
    -H "X-Api-Key: ${HC_JOBS_API_KEY}" -H "Content-Type: application/json" \
    --data-raw "$1" "${api}/api/v3/checks/"
}

# $1 = slug[/start|/fail]?rid=<job uid>, $2 = body
hcj() {
  curl -fsS -m 10 --retry 2 -o /dev/null --data-raw "$2" "${jobs_ping}/$1"
}

# How a Job's containers ended, e.g. " (dump: Error, exit 1)".
job_pod_states() {
  s=$(k get pods -n "$1" -l "batch.kubernetes.io/job-name=$2" -o json 2>/dev/null | jq -r '
    [.items[].status.containerStatuses[]?
     | (.state.terminated // .lastState.terminated) as $t | select($t != null)
     | "\(.name): \($t.reason // "terminated"), exit \($t.exitCode)"] | unique | join("; ")')
  [ -n "${s}" ] && printf ' (%s)' "${s}"
}

# Emits "T|slug|ns|cronjob|schedule|tz|grace" per watched CronJob, then
# "E|slug|ns|job|uid|state|duration|why|stale" per Job they own, oldest first.
# $base is null except on a process's first round, when it maps slug ->
# last_ping: a finished Job is then "stale" (already reported before a restart)
# unless it is its CronJob's newest finished Job and finished after the last
# ping. Without this, a restart would replay old successes and could mark a
# check up after a missed run.
# shellcheck disable=SC2016 # jq program, not shell
jobs_jq='
def macro: {"@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *", "@monthly": "0 0 1 * *",
            "@weekly": "0 0 * * 0", "@daily": "0 0 * * *", "@midnight": "0 0 * * *",
            "@hourly": "0 * * * *"}[.] // .;
def ts: if . == null or . == "" then null
        else sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601 end;
def row: map(tostring | gsub("[|\n]"; "_")) | join("|");

($extra | split(" ") | map(select(length > 0) | split("=") | {key: .[0], value: .[1]})
 | from_entries) as $x
| [$cj[0].items[]
   | "\(.metadata.namespace)/\(.metadata.name)" as $id
   | {id: $id, ns: .metadata.namespace, name: .metadata.name,
      slug: (.metadata.annotations["healthchecks.io/slug"] // $x[$id]),
      grace: (.metadata.annotations["healthchecks.io/grace"] // "3600"),
      schedule: (.spec.schedule | macro), tz: (.spec.timeZone // "UTC")}
   | select(.slug != null)] as $targets
| ($targets | map({key: .id, value: .slug}) | from_entries) as $slugs
| ($targets[] | ["T", .slug, .ns, .name, .schedule, .tz, .grace] | row),
  ([$jb[0].items[]
    | ((.metadata.ownerReferences // []) | map(select(.kind == "CronJob"))[0].name) as $owner
    | select($owner != null)
    | $slugs["\(.metadata.namespace)/\($owner)"] as $slug | select($slug != null)
    | (.status.conditions // []) as $c
    | (if any($c[]; .type == "Complete" and .status == "True") then "ok"
       elif any($c[]; .type == "Failed" and .status == "True") then "fail"
       elif .status.startTime != null then "start" else empty end) as $st
    | {slug: $slug, ns: .metadata.namespace, name: .metadata.name, uid: .metadata.uid, st: $st,
       start: (.status.startTime | ts),
       end: ((.status.completionTime // ([$c[] | select(.type == "Failed")][0].lastTransitionTime)) | ts),
       why: ([$c[] | select(.type == "Failed") | "\(.reason): \(.message)"] | join("; "))}]
   | sort_by(.end // .start)
   | (map(select(.st != "start")) | group_by(.slug) | map(max_by(.end).uid)) as $newest
   | .[]
   | .uid as $u
   | .stale = ($base != null and .st != "start"
                and (($newest | any(. == $u) | not)
                     or (($base[.slug] | ts) as $lp | $lp != null and .end <= $lp)))
   | ["E", .slug, .ns, .name, .uid, .st,
      (if .end != null and .start != null then (.end - .start | floor) else "" end),
      .why, (if .stale then 1 else 0 end)]
   | row)
'

# slug ns cronjob schedule tz grace
job_target() {
  case "$1" in
    "" | *[!a-z0-9_-]*)
      log "skipping CronJob $2/$3: slug '$1' must be lowercase [a-z0-9_-]"
      return
      ;;
  esac
  grace=$6
  case "${grace}" in "" | *[!0-9]*) grace=3600 ;; esac
  desc="Watched by the monitoring/healthchecks heartbeat runner: CronJob $2/$3 ($4 $5). Up when a Job completes, down when one fails; silence past the grace means a run was missed."
  def=$(jq -nc --arg s "$1" --arg t "k8s $2" --arg d "${desc}" --arg sc "$4" --arg tz "$5" --argjson gr "${grace}" \
    '{name: $s, slug: $s, tags: $t, desc: $d, schedule: $sc, tz: $tz, grace: $gr, channels: "*", unique: ["slug"]}')
  [ "$(cat "${state}/jobs-seen/$1" 2>/dev/null)" = "${def}" ] && return
  if upsert_job "${def}"; then
    printf '%s' "${def}" >"${state}/jobs-seen/$1"
    log "registered job check $1 (CronJob $2/$3, $4 $5, grace ${grace}s)"
  else
    log "API upsert of job check $1 failed; retrying next round"
  fi
}

# slug ns job uid state duration why stale
job_event() {
  f="${state}/jobs/$4"
  seen=$(cat "${f}" 2>/dev/null)
  [ "${seen}" = finished ] && return
  if [ "$8" = 1 ]; then
    echo finished >"${f}"
    return
  fi
  case "$5" in
    start)
      [ "${seen}" = start ] && return
      target="$1/start" body="Job $3 started"
      ;;
    ok)
      target="$1" body="Job $3 completed${6:+ in ${6}s}"
      ;;
    fail)
      target="$1/fail"
      body="Job $3 failed${6:+ after ${6}s}: ${7:-failed}$(job_pod_states "$2" "$3"). Logs: kubectl logs -n $2 job/$3"
      ;;
    *) return ;;
  esac
  # rid pairs /start with its completion, so Healthchecks shows run durations.
  if hcj "${target}?rid=$4" "${body}"; then
    if [ "$5" = start ]; then echo start >"${f}"; else echo finished >"${f}"; fi
    [ "$5" = fail ] && log "$1: ${body}"
  else
    log "ping job $1 failed"
    rm -f "${state}/jobs-seen/$1"
  fi
}

jobs_round() {
  k get cronjobs -A -o json >"${state}/cronjobs.json" || return 1
  k get jobs -A -o json >"${state}/jobs.json" || return 1

  base=null
  if [ ! -f "${state}/jobs-baselined" ]; then
    base=$(curl -fsS -m 10 -H "X-Api-Key: ${HC_JOBS_API_KEY}" "${api}/api/v3/checks/" |
      jq -c '[.checks[] | {key: .slug, value: (.last_ping // "")}] | from_entries') || return 1
  fi

  jq -rn --slurpfile cj "${state}/cronjobs.json" --slurpfile jb "${state}/jobs.json" \
    --arg extra "${HEARTBEAT_EXTRA_CRONJOBS:-}" --argjson base "${base}" \
    "${jobs_jq}" >"${state}/jobs.lines" || return 1

  job_count=0
  while IFS='|' read -r kind a b c d e f g h; do
    case "${kind}" in
      T)
        job_target "${a}" "${b}" "${c}" "${d}" "${e}" "${f}"
        job_count=$((job_count + 1))
        ;;
      E) job_event "${a}" "${b}" "${c}" "${d}" "${e}" "${f}" "${g}" "${h}" ;;
    esac
  done <"${state}/jobs.lines"

  # Forget Jobs Kubernetes has garbage-collected.
  sed -n 's/^E|[^|]*|[^|]*|[^|]*|\([^|]*\)|.*/\1/p' "${state}/jobs.lines" >"${state}/jobs.uids"
  for f in "${state}/jobs"/*; do
    [ -e "${f}" ] || continue
    grep -qxF "${f##*/}" "${state}/jobs.uids" || rm -f "${f}"
  done

  touch "${state}/jobs-baselined"
}

# --- Rounds ------------------------------------------------------------------

round() {
  # One API call per round. If it fails, ping nothing (not even the runner's
  # own check): silence is the honest answer when we can't see the cluster.
  # kubectl runs on its own line: in `kubectl | jq` the status is jq's, which
  # happily turns empty input into zero rows and a "healthy" self-ping.
  # Rows are "|"-separated, not tabs: tab is IFS whitespace, so an empty url
  # field would collapse and shift every column after it.
  workloads=$(k get deployments,statefulsets,daemonsets -A -o json) || {
    log "listing workloads failed; skipping round"
    return
  }
  rows=$(printf '%s' "${workloads}" | jq -r '
    .items[] | select(.metadata.annotations["healthchecks.io/slug"] != null)
    | [ .metadata.annotations["healthchecks.io/slug"], .kind,
        .metadata.namespace, .metadata.name,
        (.metadata.annotations["healthchecks.io/url"] // ""),
        (if .kind == "DaemonSet" then .status.numberReady // 0 else .status.readyReplicas // 0 end),
        (if .kind == "DaemonSet" then .status.desiredNumberScheduled // 0 else .spec.replicas // 1 end),
        ([.spec.selector.matchLabels // {} | to_entries[] | "\(.key)=\(.value)"] | join(",")),
        (.metadata.annotations["healthchecks.io/containers"] // "") ]
    | map(tostring | gsub("[|\n]"; "_")) | join("|")') || {
    log "parsing workloads failed; skipping round"
    return
  }

  dupes=$(printf '%s\n' "${rows}" | awk -F'|' '{ print $1; n = split($9, c, " "); for (i = 1; i <= n; i++) { sub(/^[^=]*=/, "", c[i]); print c[i] } }' | sort | uniq -d)
  [ -n "${dupes}" ] && log "WARNING: slug used by more than one workload: ${dupes}"

  count=0
  while IFS='|' read -r slug kind ns name url ready want selector containers; do
    [ -n "${slug}" ] || continue
    check_one "${slug}" "${kind}" "${ns}" "${name}" "${url}" "${ready}" "${want}" "${selector}"
    count=$((count + 1))
    for pair in ${containers}; do
      c=${pair%%=*} cslug=${pair#*=}
      if [ "${c}" = "${pair}" ] || [ -z "${selector}" ]; then
        log "skipping '${pair}' on ${kind} ${ns}/${name}: want <container>=<slug> and a label selector"
        continue
      fi
      # Can't see the pods: send nothing, and let silence speak.
      cready=$(container_ready "${ns}" "${selector}" "${c}") || {
        log "listing pods for ${cslug} failed; skipping"
        continue
      }
      check_one "${cslug}" "${kind}" "${ns}" "${name}" "" "${cready}" "${want}" "${selector}" "${c}"
      count=$((count + 1))
    done
  done <<EOF
${rows}
EOF

  job_count=0
  if [ -n "${HC_JOBS_API_KEY:-}" ] && [ -n "${HC_JOBS_PING_KEY:-}" ]; then
    jobs_round || {
      log "scheduled-job round failed; skipping self-ping"
      return
    }
  fi

  hc "${self}" "ok: ${count} service checks, ${job_count} CronJobs" || log "ping ${self} failed"
}

until upsert "${self}" infra \
  "Pinged every round by the monitoring/healthchecks heartbeat runner. Shorter grace than the service checks it feeds, so this alerts first if the runner dies." \
  120 60; do
  log "Healthchecks API not reachable yet; retrying in 10s"
  touch "${state}/last-round"
  sleep 10
done
log "started: every ${interval}s, /fail after ${fail_after} failing rounds"

while :; do
  round
  touch "${state}/last-round"
  sleep "${interval}"
done
