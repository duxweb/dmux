# Runtime Regression

Use this when verifying dmux AI runtime behavior after changing drivers, probes, wrappers, or shared runtime merge logic.

## Fast path

- `swift test --filter RuntimeDriverTests`
- `swift test --filter RuntimeLifecycleScenarioTests`
- `./scripts/dev/runtime-regression.sh`

## Real-tool runners

- Interactive PTY flow:
  - `python3 scripts/dev/runtime-scenario-runner.py --tool claude --scenario flow`
  - `python3 scripts/dev/runtime-scenario-runner.py --tool claude --scenario interrupt`
  - `python3 scripts/dev/runtime-scenario-runner.py --tool codex --scenario interrupt`
- Non-interactive flow:
  - `python3 scripts/dev/runtime-noninteractive-flow.py --tool claude`
  - `python3 scripts/dev/runtime-noninteractive-flow.py --tool codex`
  - `python3 scripts/dev/runtime-noninteractive-flow.py --tool gemini`
  - `python3 scripts/dev/runtime-noninteractive-flow.py --tool opencode`

Add `--report-json /tmp/<name>.json` when you need structured output.

## Coverage map

- `RuntimeDriverTests`
  Tool driver state transitions, hook parsing, stop/completion semantics.
- `RuntimeLifecycleScenarioTests`
  Loading lifecycle, interrupt handling, restore/resume baseline math, fresh vs restored sessions.
- `runtime-scenario-runner.py`
  Real PTY flows for tools whose interactive mode is stable under the harness.
- `runtime-noninteractive-flow.py`
  Real resume/reopen validation without depending on unstable TUIs.

## Current stable regression targets

- `claude`
  Interactive + non-interactive
- `codex`
  Non-interactive is the reliable default; interactive still depends on upstream TUI stability
- `gemini`
  Non-interactive
- `opencode`
  Non-interactive only

## Default low-cost models

- `codex`: `gpt-5.1-codex-mini`
- `claude`: `claude-haiku-4-5`
- `gemini`: `gemini-2.5-flash`
- `opencode`: `minimax/minimax-m2.5-free`

Override with `--model ...` when needed.

## Expected verification scenarios

Run enough of these to match your change:

1. New session sends two messages and loading/token growth stay correct.
2. Interrupt while responding clears loading.
3. Interrupt after completion does not reassert loading.
4. Resume historical session starts from zero baseline and grows only with new usage.
5. Reopen app and restore old session still starts from zero baseline.
6. Mix fresh and restored sessions without leaking totals or loading state between them.

## Known limits

- `opencode` interactive TUI is still not stable under the nested PTY harness.
- `codex` interactive mode can still fail upstream before hooks finish.
- These scripts are developer regression tools, not CI defaults.
