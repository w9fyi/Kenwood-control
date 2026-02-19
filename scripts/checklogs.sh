#!/usr/bin/env bash
set -euo pipefail

TAIL_LINES="${1:-200}"

LOG_FILE="${LOG_FILE:-}"
if [[ -z "${LOG_FILE}" ]]; then
  # Pick the newest log from known locations.
  #
  # Notes:
  # - When sandboxed, the app often writes under the container's "Data/Downloads/..." path.
  # - Some builds write under Data/Library/Logs.
  # - Older/local runs may write under ~/Downloads or the repo root.
  BID="${BID:-personal.Kenwood-control}"
  CANDIDATES=(
    "$HOME/Library/Containers/$BID/Data/Downloads/Kenwood control/kenwood-control.log"
    "$HOME/Library/Containers/$BID/Data/Library/Logs/kenwood-control.log"
    "$HOME/Downloads/Kenwood control/kenwood-control.log"
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/kenwood-control.log"
  )

  newest=""
  newest_m=0
  for f in "${CANDIDATES[@]}"; do
    [[ -f "$f" ]] || continue
    m="$(stat -f %m "$f" 2>/dev/null || echo 0)"
    if [[ "$m" -gt "$newest_m" ]]; then
      newest="$f"
      newest_m="$m"
    fi
  done
  LOG_FILE="$newest"
fi

if [[ ! -f "$LOG_FILE" ]]; then
  echo "No log file found at:"
  echo "  $LOG_FILE"
  echo
  echo "Tip: launch the Debug app once (it writes logs on startup)."
  exit 1
fi

echo "Log file: $LOG_FILE"
ls -lh "$LOG_FILE"
echo

echo "=== Last $TAIL_LINES lines ==="
tail -n "$TAIL_LINES" "$LOG_FILE"
echo

echo "=== Key Events (most recent first) ==="
KEY_RE='TX: ##VP|RX: ##VP|TX: (OM|FA|FB|FR|FT|RT|XT|RF|IS|SL|SH|PC|AC|SP|MV|MN|MA0|MA1|MA2|MD|DA)|RX: (OM|FA|FB|FR|FT|RT|XT|RF|IS|SL|SH|PC|AC|SP|MV|MN|MA0|MA1|MA2|MD|DA)|TX: ##KN3|RX: ##KN3|RNNoise|Noise reduction backend|NR:|LAN mic:|LAN mic capture|LAN audio receiver started|LAN: switch output|LAN: first packet|LAN audio probe|bind\\(\\) failed|Operation not permitted|KNS: Authenticated|KNS: Sending ##ID|Disconnected|Error:|Status:|FT8:|PTTKeyMonitor:|PTT: sending|TX: TX0;|TX: RX;'

rev() {
  if command -v tac >/dev/null 2>&1; then
    tac
  elif tail -r </dev/null >/dev/null 2>&1; then
    tail -r
  else
    cat
  fi
}

rg -n --no-heading -S "$KEY_RE" "$LOG_FILE" \
  | tail -n 400 \
  | rev \
  | head -n 120 \
  || true
echo

echo "=== Counts ==="
echo -n "##VP1 (VoIP start): "
rg -c 'TX: ##VP1;' "$LOG_FILE" || true
echo -n "##VP0 (VoIP stop):  "
rg -c 'TX: ##VP0;' "$LOG_FILE" || true
echo -n "Set mode (TX: OM):   "
rg -c 'TX: OM' "$LOG_FILE" || true
echo -n "Set VFO A (TX: FA):  "
rg -c 'TX: FA[0-9]{11};' "$LOG_FILE" || true
echo -n "Set data mode (DA):  "
rg -c 'TX: DA' "$LOG_FILE" || true
echo -n "Mode query (RX: MD): "
rg -c 'RX: MD' "$LOG_FILE" || true
echo -n "LAN first packet:    "
rg -c 'LAN: first packet' "$LOG_FILE" || true
echo -n "LAN receiver start:  "
rg -c 'LAN: LAN audio receiver started' "$LOG_FILE" || true
