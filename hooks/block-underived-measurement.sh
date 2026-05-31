#!/usr/bin/env bash
# Block underived measurements — bare dimensional literals that should be docgen
# markers — in prose being written or edited. A measurement that is a dimension
# of a part THIS project fabricates can be derived from a source constant; hand-
# writing the number lets it drift from the geometry. Two-stage detection: a
# cheap regex pre-filter for measurement-shaped literals (Markdown prose, or the
# comment portion of .py/.scad), then Haiku disambiguation that splits a
# derivable project dimension from a legitimately-literal external value.
#
# Fail-open: the only outcome that blocks is a clean Haiku "derivable"
# classification. Any error, timeout, missing key, or look-alike allows the
# write. Nudges once per session, then passes through.
#
# Applies only inside a repo that carries tools/docgen (the marker substitution
# engine the deny message points at); bails silently anywhere else.
#
# Diagnostic log: every invocation appends one JSONL line to
# $HOME/.claude/hooks/logs/measurement.jsonl with a "status" field.

set -euo pipefail

LOG_FILE="$HOME/.claude/hooks/logs/measurement.jsonl"
WARNED_DIR="$HOME/.claude/hooks/state"
mkdir -p "$(dirname "$LOG_FILE")" "$WARNED_DIR" 2>/dev/null || true

# Garbage-collect stale per-session warned markers (older than 7 days).
find "$WARNED_DIR" -type f -name 'measurement-warned-*' -mtime +7 -delete 2>/dev/null || true

log_status() {
  local status="$1"
  local extra_json="${2:-null}"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  {
    if [[ "$extra_json" == "null" ]]; then
      jq -nc --arg ts "$ts" --arg status "$status" '{ts: $ts, status: $status}'
    else
      jq -nc --arg ts "$ts" --arg status "$status" --argjson extra "$extra_json" '{ts: $ts, status: $status} + $extra'
    fi
  } >> "$LOG_FILE" 2>/dev/null || true
}

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')

# Per-session loop guard. Nudge once per session; after the marker is in place,
# subsequent underived-measurement writes in the same session pass through.
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
session_id_field=$(printf '%s' "$input" | jq -r '.session_id // empty')
if [[ -n "$transcript_path" ]]; then
  session_marker=$(basename "$transcript_path" .jsonl)
elif [[ -n "$session_id_field" ]]; then
  session_marker="$session_id_field"
else
  session_marker=""
fi

if [[ -n "$session_marker" && -f "$WARNED_DIR/measurement-warned-$session_marker" ]]; then
  log_status "already_warned_this_session" "$(jq -nc --arg sid "$session_marker" '{session: $sid}')"
  exit 0
fi

# Extraction mode by extension. Markdown -> whole prose (minus code spans).
# Code -> comment text only, so code constants like `boss_annulus = 3.0` don't
# fire. Everything else is skipped.
case "$file_path" in
  *.md|*.markdown) mode="md" ;;
  *.py)            mode="hash" ;;
  *.scad)          mode="slash" ;;
  *)
    log_status "skipped_filetype" "$(jq -nc --arg file "$file_path" '{file: $file}')"
    exit 0
    ;;
esac

# Extract the content being written/edited.
#   Write       -> tool_input.content
#   Edit        -> tool_input.new_string
#   MultiEdit   -> concatenation of tool_input.edits[].new_string
#   NotebookEdit-> tool_input.new_source
case "$tool_name" in
  Write)        new_content=$(printf '%s' "$input" | jq -r '.tool_input.content // empty') ;;
  Edit)         new_content=$(printf '%s' "$input" | jq -r '.tool_input.new_string // empty') ;;
  MultiEdit)    new_content=$(printf '%s' "$input" | jq -r '.tool_input.edits // [] | map(.new_string // "") | join("\n")') ;;
  NotebookEdit) new_content=$(printf '%s' "$input" | jq -r '.tool_input.new_source // empty') ;;
  *)
    log_status "wrong_tool" "$(jq -nc --arg tool "$tool_name" '{tool: $tool}')"
    exit 0
    ;;
esac

if [[ -z "$new_content" ]]; then
  log_status "empty_or_short"
  exit 0
fi

# Reduce to the surface we judge: Markdown prose minus code spans, or just the
# comment text of code.
case "$mode" in
  md)
    candidate=$(printf '%s' "$new_content" | perl -0pe 's/```.*?```//gs; s/`[^`\n]+`//g' 2>/dev/null || printf '%s' "$new_content")
    ;;
  hash)
    candidate=$(printf '%s' "$new_content" | grep '#' | sed 's/^[^#]*#//' || true)
    ;;
  slash)
    candidate=$(printf '%s' "$new_content" | perl -0777 -ne '
      my @c;
      while (/\/\*(.*?)\*\//gs) { push @c, $1 }
      for my $line (split /\n/, $_) { push @c, $1 if $line =~ m{//(.*)$} }
      print join("\n", @c);
    ' 2>/dev/null || true)
    ;;
esac

# Strip existing [value](TAG) docgen markers so already-pinned measurements
# don't fire. TAG is UPPER_SNAKE, which leaves ordinary Markdown links alone.
candidate=$(printf '%s' "$candidate" | perl -0pe 's/\[[^\]]*\]\([A-Z_][A-Z0-9_]*\)/ /g' 2>/dev/null || printf '%s' "$candidate")

if [[ -z "$candidate" ]]; then
  log_status "empty_after_strip"
  exit 0
fi

# Pre-filter + window in one pass. A measurement-shaped literal is
#   <dia><number>   diameter sign (⌀ ø Ø) then digits
#   <number> mm     digits, optional decimals, optional space, mm
#   <number>°       digits then degree sign
# Lenient by design — a false positive costs one Haiku call, a false negative is
# silent drift. Prints a ±600-char window around the first match; empty = none.
window=$(printf '%s' "$candidate" | perl -CSD -0777 -ne '
  if (/(?:[\x{2300}\x{00F8}\x{00D8}]\s*[0-9]|[0-9][0-9.]*\s*mm|[0-9][0-9.]*\s*\x{00B0})/) {
    my $s = $-[0] - 600; $s = 0 if $s < 0;
    my $len = ($+[0] - $-[0]) + 1200;
    print substr($_, $s, $len);
  }' 2>/dev/null || true)

if [[ -z "$window" ]]; then
  log_status "regex_no_match" "$(jq -nc --arg file "$file_path" '{file: $file}')"
  exit 0
fi

# Only nudge inside a repo that has the docgen engine the deny message points
# at. Walk up from the target file's directory looking for tools/docgen.
repo_root=""
d=$(dirname "$file_path")
while [[ -n "$d" && "$d" != "/" && "$d" != "." ]]; do
  if [[ -d "$d/tools/docgen" ]]; then repo_root="$d"; break; fi
  d=$(dirname "$d")
done
if [[ -z "$repo_root" ]]; then
  log_status "no_docgen_repo" "$(jq -nc --arg file "$file_path" '{file: $file}')"
  exit 0
fi

api_key_file="$HOME/.claude/anthropic_api_key"
if [[ ! -f "$api_key_file" ]]; then
  log_status "no_api_key"
  exit 0
fi
api_key=$(cat "$api_key_file")

classification_prompt='You will see a snippet from a file an AI assistant is about to write or edit. It contains a measurement (a value in mm, degrees, or a ⌀/ø diameter). Classify whether that measurement is a dimension THIS project fabricates — a part it prints, cuts, or models — so it should be derived from a source constant in code, OR an EXTERNAL value that is correctly written as a literal.

- derivable = a dimension of geometry this project defines and produces: a wall, floor, bore, boss, fillet, clearance, panel hole, trough, or an angle of the project'\''s own shape. These have (or should have) a source constant, so a hand-written number drifts from the geometry. Examples:
  - "the ⌀10 body boss disk fits within the fillet arc"
  - "a 3 mm wall and floor throughout"
  - "16° tab interior angle at the corner"
  - "22.5 mm from the reservoir'\''s lowest point to the pocket floor"

- external = a value from outside this project'\''s own geometry that is correctly a literal: a purchased-part spec, a fastener size, an imperial equivalent, a raw caliper measurement of a reference object, a packaging or standard dimension. Examples:
  - "BNUOK M3 × 12 mm DIN 912 SHCS (Amazon B0DJQGVK8S)"
  - "1/8" NPT thread"
  - "the PureSec barrel measures ⌀15.5 at max thread extent"
  - "ships in a 200 × 150 mm box"

Reply with exactly one word: derivable or external.

Snippet:
'

body=$(jq -n \
  --arg model "claude-haiku-4-5" \
  --arg prompt "$classification_prompt" \
  --arg msg "$window" \
  '{
    model: $model,
    max_tokens: 5,
    messages: [{role: "user", content: ($prompt + $msg)}]
  }')

response=$(curl -sS https://api.anthropic.com/v1/messages \
  -H "x-api-key: $api_key" \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  --max-time 8 \
  -d "$body" 2>/dev/null || echo '{}')

classification=$(printf '%s' "$response" | jq -r '.content[0].text // empty' | tr -d '[:space:].' | tr '[:upper:]' '[:lower:]')

if [[ -z "$classification" ]]; then
  log_status "haiku_no_response"
elif [[ "$classification" == "derivable" ]]; then
  # Mark this session as nudged. Subsequent underived measurements in the same
  # session pass through — the agent has the docgen context now.
  if [[ -n "$session_marker" ]]; then
    touch "$WARNED_DIR/measurement-warned-$session_marker" 2>/dev/null || true
  fi
  log_status "blocked" "$(jq -nc --arg classification "$classification" --arg file "$file_path" --arg session "$session_marker" '{classification: $classification, file: $file, session: $session}')"
  jq -n --arg repo "$repo_root" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": ("This looks like a measurement \($repo) fabricates, so the hand-written number can drift from the geometry. If this project computes this dimension, write it as a docgen marker — [value](TAG) in the comment or doc, fed from the source constant (see \($repo)/tools/docgen and existing markers, e.g. reservoir.py). If it is an external spec, an imperial equivalent, a fastener size, or a raw measurement, retry — this fires once per session, not twice.")
    }
  }'
else
  log_status "allowed" "$(jq -nc --arg classification "$classification" '{classification: $classification}')"
fi
