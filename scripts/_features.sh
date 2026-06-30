# scripts/_features.sh — feature-ledger helpers. SOURCE this (don't execute).
#
# The work queue is the features/ directory — ONE features/<id>.json per ticket,
# the entry object alone — so concurrent branches never conflict on it (a single
# shared JSON array couldn't merge). Completed tickets are appended to
# feature_list.archive.jsonl (one compact entry per line, merge=union via
# .gitattributes) by scripts/archive-passing.sh. See features/README.md.
#
# features_live_json aggregates features/*.json back into the legacy
# {"features":[...]} shape so init.sh / handoff.sh read it uniformly. A legacy
# monolithic feature_list.json is still honoured as a fallback (for repos that
# haven't migrated), but the features/ directory is the default and wins.

FEATURES_DIR="${FEATURES_DIR:-features}"
FEATURE_LIST="${FEATURE_LIST:-feature_list.json}"
FEATURES_ARCHIVE="${FEATURES_ARCHIVE:-feature_list.archive.jsonl}"

# All LIVE tickets aggregated into {"features":[...]} on stdout (sorted by id for
# stable output). Empty (no tickets anywhere) yields {"features":[]}.
features_live_json() {
  if compgen -G "$FEATURES_DIR/*.json" >/dev/null 2>&1; then
    jq -s '{features: (sort_by(.id))}' "$FEATURES_DIR"/*.json
  elif [[ -f "$FEATURE_LIST" ]]; then
    jq '{features: (.features // [])}' "$FEATURE_LIST"
  else
    printf '{"features": []}\n'
  fi
}

# Path to one ticket's file in the per-ticket layout (does not check existence).
feature_file() { printf '%s/%s.json\n' "$FEATURES_DIR" "$1"; }
