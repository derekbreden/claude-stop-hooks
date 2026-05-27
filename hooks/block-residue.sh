#!/usr/bin/env bash
# Block residue (justification, defense, decision narrative) in files being
# written or edited. Two-stage detection: cheap regex pre-filter on the new
# content, then Haiku disambiguation on the candidate region. Fail-open on any
# error.
#
# Residue = the author going beyond describing what is, to explain, defend, or
# narrate. See $HOME/Developer/homesodamachine/calibration/Principle.md for the
# discipline; You.md and Framing.md in the same directory carry the live
# calibration the principle is distilled from.
#
# Diagnostic log: every invocation appends one JSONL line to
# $HOME/.claude/hooks/logs/residue.jsonl with a "status" field.

set -euo pipefail

CALIBRATION_DIR="$HOME/Developer/homesodamachine/calibration"
LOG_FILE="$HOME/.claude/hooks/logs/residue.jsonl"
WARNED_DIR="$HOME/.claude/hooks/state"
mkdir -p "$(dirname "$LOG_FILE")" "$WARNED_DIR" 2>/dev/null || true

# Garbage-collect stale per-session warned markers (older than 7 days). The
# markers are empty files, but the directory shouldn't grow without bound.
find "$WARNED_DIR" -type f -name 'residue-warned-*' -mtime +7 -delete 2>/dev/null || true

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

# Bail if the calibration files aren't where we'd point the agent.
if [[ ! -f "$CALIBRATION_DIR/Principle.md" ]]; then
  log_status "no_calibration_files"
  exit 0
fi

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')

# Per-session loop guard. The hook bothers an agent once per session; after
# that the marker file is in place and subsequent residue writes pass
# through. Session is identified by the transcript path basename (the
# session UUID), falling back to a session_id field if that's not present.
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
session_id_field=$(printf '%s' "$input" | jq -r '.session_id // empty')
if [[ -n "$transcript_path" ]]; then
  session_marker=$(basename "$transcript_path" .jsonl)
elif [[ -n "$session_id_field" ]]; then
  session_marker="$session_id_field"
else
  session_marker=""
fi

if [[ -n "$session_marker" && -f "$WARNED_DIR/residue-warned-$session_marker" ]]; then
  log_status "already_warned_this_session" "$(jq -nc --arg sid "$session_marker" '{session: $sid}')"
  exit 0
fi

# Extract the content being written/edited.
#   Write       -> tool_input.content
#   Edit        -> tool_input.new_string
#   MultiEdit   -> concatenation of tool_input.edits[].new_string
#   NotebookEdit-> tool_input.new_source
case "$tool_name" in
  Write)
    new_content=$(printf '%s' "$input" | jq -r '.tool_input.content // empty')
    ;;
  Edit)
    new_content=$(printf '%s' "$input" | jq -r '.tool_input.new_string // empty')
    ;;
  MultiEdit)
    new_content=$(printf '%s' "$input" | jq -r '.tool_input.edits // [] | map(.new_string // "") | join("\n")')
    ;;
  NotebookEdit)
    new_content=$(printf '%s' "$input" | jq -r '.tool_input.new_source // empty')
    ;;
  *)
    log_status "wrong_tool" "$(jq -nc --arg tool "$tool_name" '{tool: $tool}')"
    exit 0
    ;;
esac

# Skip the calibration files themselves — they contain residue-vocabulary by
# nature and shouldn't trigger the hook that points at them.
case "$file_path" in
  */calibration/*)
    log_status "skipped_calibration" "$(jq -nc --arg file "$file_path" '{file: $file}')"
    exit 0
    ;;
esac

# Skip binary / structured files where residue-prevention doesn't apply.
case "$file_path" in
  *.dxf|*.png|*.jpg|*.jpeg|*.gif|*.svg|*.pdf|*.bin|*.zip|*.tar|*.gz|*.3mf|*.stl|*.obj|*.json|*.lock|*.toml|*.yaml|*.yml)
    log_status "skipped_non_prose" "$(jq -nc --arg file "$file_path" '{file: $file}')"
    exit 0
    ;;
esac

if [[ -z "$new_content" || ${#new_content} -lt 60 ]]; then
  log_status "empty_or_short" "$(jq -nc --argjson len "${#new_content}" '{len: $len}')"
  exit 0
fi

# Strip backtick-delimited spans (fenced blocks and inline code) before pattern
# matching. Documentation quoting trigger patterns should not classify as
# residue.
new_content=$(printf '%s' "$new_content" | perl -0pe 's/```.*?```//gs; s/`[^`\n]+`//g' 2>/dev/null || printf '%s' "$new_content")
if [[ -z "$new_content" || ${#new_content} -lt 60 ]]; then
  log_status "empty_after_strip"
  exit 0
fi

# Pre-filter: cheap regex for candidate residue surface forms.
#   - history narrative: previously, originally, used to be, switched from,
#     changed from, moved away from, no longer
#   - decision narrative: we chose / considered / rejected / decided, the
#     rationale, the reason(s) is/are/why/for, the reasoning behind, chosen /
#     selected / picked because, intentionally [verb], deliberately [verb]
#   - defense against alternatives: rather than (verb|article), instead of
#     (verb|article), alternatives considered / ruled out / rejected, designs
#     considered / ruled out / rejected, trade-off, not a compromise / substitute,
#     because the alternative, specifically so, would otherwise
#   - claim of rightness: is the right / correct X
# The pattern is intentionally lenient — false positives are cheap (one Haiku
# call) but false negatives are silent slips. Extend when the log shows
# something getting past.
pattern='([Pp]reviously|[Oo]riginally|[Uu]sed[ \-]+to[ \-]+(be|use|have|do|exist)|[Ss]witched[ \-]+from|[Cc]hanged[ \-]+from|[Mm]oved[ \-]+away[ \-]+from|[Nn]o[ \-]+longer|[Ww]e[ \-]+(chose|considered|rejected|decided)|[Tt]he[ \-]+rationale|[Rr]ather[ \-]+than[ \-]+(using|having|going[ \-]+with|choosing|doing|the|a|an)|[Ii]nstead[ \-]+of[ \-]+(using|having|going[ \-]+with|choosing|the|a|an)|[Aa]lternatives?[ \-]+(considered|ruled[ \-]+out|rejected)|[Dd]esigns?[ \-]+(considered|ruled[ \-]+out|rejected)|[Tt]rade[ \-]?offs?|[Nn]ot[ \-]+a[ \-]+(compromise|substitute)|[Bb]ecause[ \-]+the[ \-]+alternative|[Tt]he[ \-]+reasoning[ \-]+behind|[Tt]he[ \-]+(reason|reasons)[ \-]+(is|are|why|for)|[Cc]hosen[ \-]+because|[Ss]elected[ \-]+because|[Pp]icked[ \-]+because|[Ii]ntentionally[ \-]+[[:alpha:]]+|[Dd]eliberately[ \-]+[[:alpha:]]+|[Ss]pecifically[ \-]+so[ \-]+[[:alpha:]]|[Ii]s[ \-]+the[ \-]+(right|correct)[ \-]+[[:alpha:]]|[Ww]ould[ \-]+otherwise)'

if ! printf '%s\n' "$new_content" | grep -qE "$pattern"; then
  log_status "regex_no_match" "$(jq -nc --argjson len "${#new_content}" '{len: $len}')"
  exit 0
fi

# Window: ±600 chars around the first match position. Position-based rather
# than line-based, so very long unbroken paragraphs still get the match in view.
window=$(printf '%s' "$new_content" | awk -v pat="$pattern" '
  { full = full $0 "\n" }
  END {
    if (match(full, pat)) {
      start = RSTART - 600
      if (start < 1) start = 1
      end = RSTART + RLENGTH + 600
      if (end > length(full)) end = length(full)
      print substr(full, start, end - start + 1)
    }
  }
')

api_key_file="$HOME/.claude/anthropic_api_key"
if [[ ! -f "$api_key_file" ]]; then
  log_status "no_api_key"
  exit 0
fi
api_key=$(cat "$api_key_file")

classification_prompt='You will see a snippet from a file an AI assistant is about to write or edit. Classify whether the snippet contains RESIDUE — the author going beyond describing what currently is, to explain, defend, justify, or narrate.

- residue = explains WHY something is the way it is by reference to alternatives that were rejected, decisions that were made, or how it came to be. Goes beyond present-tense description into justification, defense, or history. Examples:
  - "We chose to ship the umbilical pre-assembled rather than separately because customers would otherwise have to thread tubes through the shank"
  - "Designs ruled out: split halves, living hinge, C-clip, tab-and-slot"
  - "Previously the plate was solid; switching to open channels lets the customer slide it on"
  - "This is not a compromise — it is the same product as a can"
  - "The rationale is that the customer needs to install one-handed"

- describing = states facts, motion, or geometry without defending or justifying. Words like "rather than", "previously", or "originally" can appear here without being residue if they describe what is, not defend a choice. Examples:
  - "The rim arc extends counterclockwise rather than clockwise"
  - "The plate slides laterally from below onto the dangling umbilical"
  - "Originally signed by the manufacturer at the factory"
  - "Each cylinder seats in its terminal pocket"

Reply with exactly one word: residue or describing.

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
elif [[ "$classification" == "residue" ]]; then
  # Mark this session as warned. Subsequent residue writes in the same
  # session will pass through — the agent has the calibration context now
  # and the decision is theirs.
  if [[ -n "$session_marker" ]]; then
    touch "$WARNED_DIR/residue-warned-$session_marker" 2>/dev/null || true
  fi
  log_status "blocked" "$(jq -nc --arg classification "$classification" --arg file "$file_path" --arg session "$session_marker" '{classification: $classification, file: $file, session: $session}')"
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "Before continuing, read /Users/derekbredensteiner/Developer/homesodamachine/calibration/Principle.md and the conversations it points at (You.md and Framing.md, in the same directory). What you were about to write was caught as residue. Read those files first, then look at what you wrote. If after reading you still want to write what you had, retry — this hook bothers you once per session, not twice."
    }
  }'
else
  log_status "allowed" "$(jq -nc --arg classification "$classification" '{classification: $classification}')"
fi
