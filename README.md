# claude-code-hooks

Claude Code hooks. Three Stop hooks block specific outputs from the assistant: effort estimates, hedges that don't name a concern, disagreement framed as a question. Three PreToolUse hooks block specific writes: project memory files, content containing residue (justification, defense, decision narrative — the author going beyond describing what is), and underived measurements (bare dimensional literals that should be docgen markers fed from a source constant).

This is a personal tool, put on GitHub in case it helps someone running similar configurations. It is not a polished, configurable, cross-platform library — read the next section before assuming it'll work for you.

## Who this is for

You'll get value from this if **all** of the following are true:

- You're using **Claude Code** and want it to block specific patterns in the assistant's turns and tool calls.
- For the Stop hooks: you're OK with **Anthropic API charges** for the Haiku second-stage classifications (one small Haiku call per Stop event when the regex pre-filter matches — usually a tiny fraction of turns).
- You're comfortable with **bash + jq + curl + perl** in your hook scripts and editing `~/.claude/settings.json` by hand.

You will *not* get value from this if:

- You want a **UI** for configuring patterns.
- You want **portable, OS-agnostic** hooks (these use `tail -r`/`tac` and other shell quirks).
- You want **fine-grained control over which sessions** a hook applies to (these run on every relevant event globally).

## The hooks

### Stop hooks (regex + Haiku two-stage)

These run after each assistant turn. Each one runs a cheap regex pre-filter against the last assistant message; if it matches, a windowed snippet goes to Claude Haiku for disambiguation; if Haiku confirms the targeted pattern, the turn is blocked with a `reason` returned to the assistant.

- **`block-effort-estimate.sh`** — catches phrasings like "this'll take a day", "maybe a few hours", "weeks not months", "a couple of weeks". An effort estimate from an LLM is not tied to reality: it is pattern-matched from training data, where humans wrote estimates of work they were doing — work the LLM will do entirely differently. The block message asks the assistant to rewrite without one.

- **`block-unexplained-hedge.sh`** — catches "I'm not sure", "I might be wrong", "this could be off" when the assistant doesn't name the underlying concern. The block message asks the assistant to explain the concern rather than remove the hedge. Substantive hedges (where the concern is named) pass through; social/habitual hedges get blocked.

- **`block-question-as-disagreement.sh`** — catches "I notice X — was that intended?" / "Did you mean to Y?" / "Is that on purpose?" when the assistant frames a structural disagreement as a question. The block message asks the assistant to state the disagreement directly. Genuine information-gathering questions pass through; disagreement framed as a question gets blocked.

### PreToolUse hooks

These run before specific tool calls.

- **`block-memory-write.sh`** — catches `Write` / `Edit` / `MultiEdit` / `NotebookEdit` calls whose target path is under any `~/.claude/projects/*/memory/` directory. The deny message asks the assistant to encode the lesson by example in the work it's doing rather than as a memory note. (`Bash` writes to memory paths via `echo >` are intentionally not blocked — the hook would otherwise gate every shell command for a threat that hasn't materialized.)

- **`block-residue.sh`** — catches `Write` / `Edit` / `MultiEdit` / `NotebookEdit` calls whose new content contains residue (justification, defense, decision narrative — the author going beyond describing what is). Two-stage like the Stop hooks: regex pre-filter on the new content, Haiku adjudication on a ±600-char window around the first match. The deny message points the assistant at three calibration files (`Principle.md`, `You.md`, `Framing.md`) in `~/Developer/homesodamachine/calibration/` and asks them to read those before looking at what they wrote. **Fires once per session, not twice** — once an agent has been pointed at the calibration, subsequent residue writes in the same session pass through. A marker file at `~/.claude/hooks/state/residue-warned-<session-id>` records the warning; markers older than 7 days are garbage-collected on each invocation. Skips binary/structured files (`.dxf`, `.json`, `.yaml`, etc.) and the calibration files themselves. Fires only when the calibration files exist at the expected path; bails silently otherwise.

- **`block-underived-measurement.sh`** — catches `Write` / `Edit` / `MultiEdit` / `NotebookEdit` calls that introduce a bare dimensional literal (a value in mm, degrees, or a `⌀`/`ø` diameter) where the dimension is one this project fabricates and so should be a docgen marker fed from a source constant. Two-stage like `block-residue.sh`: a lenient regex pre-filter for measurement-shaped literals, then Haiku adjudication on a ±600-char window that splits a *derivable* project dimension (a wall, bore, boss, fillet, angle of the project's own geometry → nudge) from an *external* value that is correctly a literal (a fastener size, imperial equivalent, vendor spec, raw caliper measurement → pass). Scopes by extension — Markdown is judged whole, `.py`/`.scad` are reduced to their **comment text** so code constants like `boss_annulus = 3.0` don't fire — and strips existing `[value](TAG)` markers first so already-pinned values don't fire. The deny message points the assistant at the repo's `tools/docgen` and the `[value](TAG)` marker syntax. **Fires once per session, not twice**, via `~/.claude/hooks/state/measurement-warned-<session-id>` (same 7-day GC). Applies only inside a repo that carries `tools/docgen` (found by walking up from the target file); bails silently anywhere else.

## How the Stop hooks work

Each Stop hook follows the same shape:

1. Read the assistant's last turn from the session transcript JSONL.
2. Strip backtick-delimited spans (so docs that quote the hook's own trigger patterns don't fire the hook on itself).
3. Run a **cheap regex pre-filter** against the last turn. If nothing matches, exit silently.
4. If the regex matches, extract a **±800-char window** of context around the match.
5. Send the window to **Claude Haiku 4.5** with a classification prompt that distinguishes the targeted pattern from the look-alike (effort vs projection; substantive vs social hedge; genuine question vs disagreement-framed-as-question).
6. If Haiku classifies as the targeted pattern, emit a `block` decision with a `reason`.

The two-stage design keeps API cost down (most turns never reach Haiku) while keeping the catch precise (Haiku sees real context, not just the matched fragment).

## Logging

The three Stop hooks, `block-residue.sh`, and `block-underived-measurement.sh` each append one JSONL line per event to `~/.claude/hooks/logs/<hook-name>.jsonl` with a `status` field identifying which code path was taken:

- `loop_guard` — re-entry from a revision attempt, skipped (Stop hooks only)
- `no_transcript` / `no_assistant_message` / `empty_or_short_text` / `empty_after_strip` — nothing to check (Stop hooks)
- `wrong_tool` / `skipped_calibration` / `skipped_non_prose` / `empty_or_short` / `no_calibration_files` — file or tool filtered out (`block-residue.sh` only)
- `skipped_filetype` / `no_docgen_repo` / `empty_after_strip` — file filtered out: not `.md`/`.py`/`.scad`, not inside a `tools/docgen` repo, or no prose left after stripping comments and markers (`block-underived-measurement.sh` only)
- `already_warned_this_session` — session marker exists from a prior nudge in the same session; hook passes through (`block-residue.sh` and `block-underived-measurement.sh`)
- `regex_no_match` — pre-filter didn't match; **Stop-hook log lines include `last_400_chars` of the response so you can see what slipped through**
- `no_api_key` — `~/.claude/anthropic_api_key` is missing
- `haiku_no_response` — Haiku call made but empty response (timeout, network failure, etc.)
- `allowed` — Haiku classified as the look-alike; no block emitted
- `blocked` — Haiku classified as the targeted pattern; block was emitted

The `regex_no_match` lines are the diagnostic surface for tuning. If a pattern slips through in normal use, grep the log:

```sh
grep regex_no_match ~/.claude/hooks/logs/effort-estimate.jsonl | tail
```

Identify the shape that got past, add it to the regex pattern in the script.

`block-memory-write.sh` does not log. It is structurally much simpler (path comparison only) and has no two-stage decision to diagnose.

## Installing

1. Clone this repo somewhere on your machine.
2. `chmod +x hooks/*.sh`.
3. Drop your Anthropic API key into `~/.claude/anthropic_api_key` (for the Stop hooks; plain text, one line, no quotes).
4. Wire the hooks up in `~/.claude/settings.json` — see `examples/settings.json` for the shape.

For paths in `settings.json`: the example uses `$HOME/.claude/hooks/...` which assumes you've copied the scripts into that directory. An alternative is to point `settings.json` directly at your clone (e.g. `$HOME/path/to/claude-code-hooks/hooks/...`). That keeps a single source of truth on disk: edit in the clone, run from the clone, commit and push from the clone.

## Tuning

The regex pattern is one line near the top of each Stop-hook script. Extend it as you find slips in the log. The Haiku stage filters out matches that don't fit the pattern definition: a regex that matches widely costs an API call per match but does not block on the look-alike.

The classification prompts are also in each script. If Haiku classifies in a direction other than what you want, the prompt is where you'd adjust the examples or definitions.

The `reason` message — what the assistant sees when blocked — is a `jq -n` literal near the bottom of each script. Rewrite it however you want it to read.

## Files

- `hooks/block-effort-estimate.sh` — effort-estimate hook (Stop, regex + Haiku two-stage)
- `hooks/block-unexplained-hedge.sh` — hedge hook (Stop, regex + Haiku two-stage)
- `hooks/block-question-as-disagreement.sh` — question-as-disagreement hook (Stop, regex + Haiku two-stage)
- `hooks/block-memory-write.sh` — memory-write hook (PreToolUse, path comparison only)
- `hooks/block-residue.sh` — residue hook (PreToolUse, regex + Haiku two-stage)
- `hooks/block-underived-measurement.sh` — underived-measurement hook (PreToolUse, regex + Haiku two-stage)
- `examples/settings.json` — example `~/.claude/settings.json` snippet wiring all six hooks
