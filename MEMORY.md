Claude Code hooks: three Stop hooks (effort estimates, unexplained hedges, questions-as-disagreement) plus three PreToolUse hooks (writes to project memory files; residue in new file content; underived measurements in new prose).

The three Stop hooks are regex pre-filter + Claude Haiku second-stage classification; the regex is intentionally lenient and the Haiku stage handles disambiguation. Per-hook logs land in `~/.claude/hooks/logs/<hook-name>.jsonl` with a `status` field identifying each code path; `regex_no_match` entries include the last 400 characters of the response so slips through the pre-filter can be found and the pattern extended.

`block-memory-write.sh` is the simplest PreToolUse hook — a path comparison against `~/.claude/projects/*/memory/`, emitting a `permissionDecision=deny`. No regex, no Haiku, no log. `block-residue.sh` and `block-underived-measurement.sh` are PreToolUse but two-stage (regex + Haiku) like the Stop hooks: they judge the new content of a write, nudge once per session via a marker in `~/.claude/hooks/state/`, and log to their own JSONL. `block-underived-measurement.sh` reduces `.py`/`.scad` to comment text and strips existing `[value](TAG)` markers before matching, and applies only inside a repo carrying `tools/docgen`.

When extending a Stop-hook regex: look at `grep regex_no_match ~/.claude/hooks/logs/<name>.jsonl | tail`, find the shape that slipped, add it to the one-line pattern near the top of the script. Don't worry about false positives at the regex stage — the Haiku stage rejects matches that don't fit the pattern definition.

When extending the Haiku prompt: the examples in the classification prompt are the levers. If Haiku is mis-classifying in one direction, adjust the examples or the definitions in the prompt body, not the regex.

`examples/settings.json` is the wiring example for `~/.claude/settings.json`.
