#!/usr/bin/env bash
# Record the current GHA step start on the checkpoint share for HTTP attribution.
set -euo pipefail
NAME="${1:?step name}"
CHECKPOINT="${CHECKPOINT_DIR:-/mnt/checkpoint}"
mkdir -p "${CHECKPOINT}"
python3 - "${CHECKPOINT}/steps.jsonl" "${NAME}" <<'PY'
import datetime, json, sys
path, name = sys.argv[1], sys.argv[2]
row = {
    "event_type": "WORKFLOW_STEP",
    "name": name,
    "started_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
}
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(row) + "\n")
print(f"step={name} stamped -> {path}")
PY
