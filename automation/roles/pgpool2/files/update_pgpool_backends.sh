#!/bin/bash
#
# Patroni callback: keep pgpool's backend_* directives in sync with the
# current Patroni leader. Invoked by Patroni on role transitions.
#
# Patroni invokes callbacks as:
#   <script> <action> <role> <cluster_name>
#
# When this node transitions to master (or starts up), discover the
# current leader and replicas via patronictl, rewrite pgpool.conf's
# backend block, and `pgpool reload`.
#
# Idempotent: if leader is unchanged, exits with no-op.

set -euo pipefail

ACTION="${1:-}"
ROLE="${2:-}"
CLUSTER_NAME="${3:-}"

PGPOOL_CONF="/etc/pgpool2/pgpool.conf"
STATE_FILE="/var/run/pgpool2/current_leader"
LOG_TAG="pgpool-callback"

log() { logger -t "$LOG_TAG" "$*" || true; echo "[$LOG_TAG] $*" >&2; }

case "$ACTION" in
  on_role_change|on_start|on_restart|on_reload) ;;
  *) log "skipping action=$ACTION"; exit 0 ;;
esac

LEADER_IP=$(patronictl -c /etc/patroni/patroni.yml list -f json 2>/dev/null \
  | python3 -c '
import sys, json
for m in json.load(sys.stdin):
    if m.get("Role") == "Leader":
        print(m.get("Host"))
        break
' || true)

if [[ -z "$LEADER_IP" ]]; then
  log "could not determine leader; aborting"
  exit 1
fi

if [[ -f "$STATE_FILE" ]] && [[ "$(cat "$STATE_FILE")" == "$LEADER_IP" ]]; then
  log "leader unchanged ($LEADER_IP); no-op"
  exit 0
fi

log "new leader: $LEADER_IP"

mapfile -t ALL_NODES < <(patronictl -c /etc/patroni/patroni.yml list -f json 2>/dev/null \
  | python3 -c '
import sys, json
for m in json.load(sys.stdin):
    print(m.get("Host"))
')

REPLICAS=()
for ip in "${ALL_NODES[@]}"; do
  [[ "$ip" != "$LEADER_IP" && -n "$ip" ]] && REPLICAS+=("$ip")
done

# Build a new BACKENDS block as text, then splice it into pgpool.conf,
# replacing the previous block (delimited by '# BACKENDS' header up to
# the next '#---' that follows our 'AUTHENTICATION' section).
BLOCK=$(mktemp)
trap 'rm -f "$BLOCK"' EXIT

{
  echo "#------------------------------------------------------------------------------"
  echo "# BACKENDS  (rewritten by Patroni callback at $(date -u +%FT%TZ))"
  echo "#------------------------------------------------------------------------------"
  printf "backend_hostname0 = '%s'\n" "$LEADER_IP"
  echo "backend_port0 = 5432"
  echo "backend_weight0 = 0"
  echo "backend_flag0 = 'DISALLOW_TO_FAILOVER'"
  echo "backend_application_name0 = 'primary'"
  i=1
  for r in "${REPLICAS[@]}"; do
    echo
    printf "backend_hostname%d = '%s'\n" "$i" "$r"
    printf "backend_port%d = 5432\n" "$i"
    printf "backend_weight%d = 1\n" "$i"
    printf "backend_flag%d = 'ALLOW_TO_FAILOVER'\n" "$i"
    printf "backend_application_name%d = 'replica%d'\n" "$i" "$i"
    i=$((i+1))
  done
  echo
} > "$BLOCK"

TMP=$(mktemp)
python3 <<EOF >"$TMP"
import re, pathlib
src = pathlib.Path("$PGPOOL_CONF").read_text()
block = pathlib.Path("$BLOCK").read_text()
# Replace the whole BACKENDS section: from a comment line containing
# "BACKENDS" up to the next section header (line starting with "#----"
# then "# AUTHENTICATION").
pattern = re.compile(
    r"#-+\n# BACKENDS.*?(?=#-+\n# AUTHENTICATION)",
    re.DOTALL,
)
if not pattern.search(src):
    raise SystemExit("pgpool.conf BACKENDS block not found")
out = pattern.sub(block, src, count=1)
print(out, end="")
EOF

if ! grep -q "^backend_hostname0" "$TMP"; then
  log "rewrite failed (no backend_hostname0 in result); aborting"
  rm -f "$TMP"
  exit 1
fi

install -m 0644 -o postgres -g postgres "$TMP" "$PGPOOL_CONF"
rm -f "$TMP"
echo "$LEADER_IP" > "$STATE_FILE"
chmod 0644 "$STATE_FILE"

log "pgpool.conf updated; reloading"
if pgpool reload >/dev/null 2>&1; then
  log "pgpool reloaded successfully"
else
  log "pgpool reload failed; you may need 'systemctl restart pgpool2'"
  exit 1
fi
