#!/usr/bin/env bash
# Real install and download numbers, from the edge Worker's dataset.
#
#   CLOUDFLARE_API_TOKEN=... ./stats.sh [days]        (default 30)
#
# The token needs one permission: Account → Account Analytics → Read.
# Create it at https://dash.cloudflare.com/profile/api-tokens.
#
# Column meanings are defined in src/index.js; this file must match it.
set -euo pipefail

DAYS="${1:-30}"
ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-9c0e613e70956e45e5eab1a569e2e271}"
DATASET="kiddyproof_stats"

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  echo "CLOUDFLARE_API_TOKEN is not set (needs Account Analytics: Read)." >&2
  exit 1
fi

sql() {
  curl -sS "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/analytics_engine/sql" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    --data-binary "$1"
}

# Analytics Engine samples under heavy load; SUM(_sample_interval) is the
# unbiased count, count() is the number of stored rows. At our volume they match.
WINDOW="timestamp > NOW() - INTERVAL '${DAYS}' DAY"

echo "kiddyproof — last ${DAYS} days"
echo

echo "ACTIVE INSTALLS  (unique Sparkle heartbeats; one row per install)"
sql "SELECT blob9 AS install, blob8 AS version, blob7 AS country, SUM(_sample_interval) AS pings
     FROM ${DATASET}
     WHERE index1 = 'heartbeat' AND blob12 = '1' AND ${WINDOW}
     GROUP BY install, version, country" \
| python3 -c '
import json, sys, collections
d = json.load(sys.stdin)
rows = d.get("data", [])
print(f"  active installs: {len(rows)}")
byv = collections.Counter(r["version"] for r in rows)
for v, n in sorted(byv.items(), key=lambda x: (-x[1], x[0])): print(f"    {v or \"?\":8} {n}")
byc = collections.Counter(r["country"] for r in rows)
print("  by country:", ", ".join(f"{c or \"?\"}={n}" for c, n in byc.most_common(8)))
'
echo

echo "DOWNLOADS  (from the site's /download link)"
sql "SELECT blob2 AS os, blob4 AS bot, blob5 AS src, SUM(_sample_interval) AS n
     FROM ${DATASET}
     WHERE index1 = 'download' AND ${WINDOW}
     GROUP BY os, bot, src
     ORDER BY n DESC" \
| python3 -c '
import json, sys
rows = json.load(sys.stdin).get("data", [])
real = sum(int(r["n"]) for r in rows if r["os"] == "macOS" and r["bot"] == "0")
bots = sum(int(r["n"]) for r in rows if r["bot"] == "1")
other = sum(int(r["n"]) for r in rows) - real - bots
print(f"  real (macOS, not bot): {real}")
print(f"  bots:                  {bots}")
print(f"  non-Mac humans:        {other}   (should be ~0 — the site no longer offers them the DMG)")
print("  breakdown:")
for r in rows: print(f"    {r[\"os\"]:9} bot={r[\"bot\"]} src={r[\"src\"] or \"-\":7} {r[\"n\"]}")
'
echo

echo "REAL DOWNLOADS PER DAY  (macOS, not bot)"
sql "SELECT toStartOfInterval(timestamp, INTERVAL '1' DAY) AS day, SUM(_sample_interval) AS n
     FROM ${DATASET}
     WHERE index1 = 'download' AND blob3 = '1' AND blob4 = '0' AND ${WINDOW}
     GROUP BY day ORDER BY day" \
| python3 -c '
import json, sys
for r in json.load(sys.stdin).get("data", []): print(f"    {str(r[\"day\"])[:10]}  {r[\"n\"]}")
'
echo

echo "WHO THE BOTS ARE  (top networks hitting /download or the appcast without Sparkle)"
sql "SELECT blob11 AS network, blob1 AS kind, SUM(_sample_interval) AS n
     FROM ${DATASET}
     WHERE blob4 = '1' AND ${WINDOW}
     GROUP BY network, kind ORDER BY n DESC LIMIT 12" \
| python3 -c '
import json, sys
for r in json.load(sys.stdin).get("data", []): print(f"    {r[\"kind\"]:9} {r[\"network\"] or \"?\":40} {r[\"n\"]}")
'
