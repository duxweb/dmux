# Runtime Regression

Use this when verifying the current dmux AI hook-only runtime path.

## Fast path

- `swift test --filter AIRuntimeIngressHookEventTests`
- `swift test --filter AIRuntimeIngressSocketTests`
- `swift test --filter AISessionStoreTests`

## Manual in-terminal notification test

Use this inside a dmux terminal when you want to trigger a lightweight Codex notification-style hook event without launching the real Codex CLI flow.

If needed, reload the shell hook script first:

- `source "$DMUX_ZSH_HOOK_SCRIPT"`

Available commands:

```bash
codex.notice.test
codex.notice.test type=idle_prompt "Task finished"
codex.notice.test type=permission-request message="Need approval"
```

`codex.notice.test` sends a unified `ai-hook` event for tool `codex` with kind `needsInput` and notification metadata. It is only for manually checking:

- terminal -> runtime socket delivery
- `AIRuntimeIngressService` ingest
- `AISessionStore` state update
- UI notification / live state rendering
