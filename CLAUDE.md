# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

macOS 14+ menu bar app (SwiftPM, Swift 6 strict concurrency, zero dependencies) showing
Claude Code, Codex, and Cursor usage across multiple accounts.

## Commands

- `swift test` — run the test suite
- `make app` — release build + bundle at `dist/AgentBar.app`, signed with `AgentBar Dev` when that cert exists (`Packaging/make-signing-cert.sh`), ad-hoc otherwise
- `make install` — copy the bundle to `/Applications` (run `killall AgentBar` first if it's running)
- `make zip` — build + `ditto`-zip the bundle to `dist/AgentBar.zip` for sharing (receiver needs one-time "Open Anyway" in System Settings)
- `swiftlint lint --quiet` — must report zero violations (config: `.swiftlint.yml`)

## Invariants (do not break)

- The refresh loop `.task` is attached to the MenuBarExtra **label** image in `AgentBarApp`,
  not the dropdown content — dropdown views are destroyed whenever the menu closes. Do not move it.
- Claude OAuth tokens are **read-only** by design: never refresh or write them back (a refresh
  rotates the token and would invalidate the CLI's stored credential). Expired tokens show
  "open claude to refresh" and recover after the CLI runs. Codex tokens ARE refreshed, with
  atomic write-back to `auth.json` (`CodexTokenRefresher`).
- Cursor tokens are **read-only** too: `CursorCredentials` reads `cursorAuth/accessToken` from
  `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` with `SQLITE_OPEN_READONLY`;
  never refresh or write it. Grok Bot signs in with the same Cursor account, so one row covers both,
  but its weekly limit is a separate pool (see Gotchas).
- Keychain service name for a Claude config dir: `"Claude Code-credentials-"` + first 8 hex chars
  of SHA-256(dir path, no trailing slash). `~/.claude` has TWO candidates — the CLI uses the bare
  `"Claude Code-credentials"` when `CLAUDE_CONFIG_DIR` is unset but the hashed name when it is set
  explicitly (even to `~/.claude`) — so reads must check both and keep the freshest token
  (`ClaudeKeychain.serviceNames`). Freshest-wins applies only while both slots hold the SAME
  account; when their `subscriptionType`s differ the row shows a conflict error instead
  (another app can rewrite the bare slot with a different account).
- Everything in `AgentBarCore` is injectable (`HTTPTransport`, `keychainRead`, the Cursor SQLite read, `now:`, `home:`);
  tests must never touch the network, the real Keychain, or the real home directory.

## Gotchas

- Keychain reads must stay silent: macOS 26 ignores "Always Allow" ACL grants for this
  non-notarized app (even with the stable `AgentBar Dev` cert), so Claude credentials are read
  via Apple-signed `/usr/bin/security` (`ClaudeKeychainCLI`), SecItem only as fallback. Failed
  reads are cached with a 300s backoff (`ClaudeTokenCache`) so a fallback prompt can't repeat
  every refresh tick. A consent prompt appearing at all is a regression.
- Duplicate Keychain items on the same service name exist in the wild (seen live on this machine);
  both read paths pick the current user's newest item, else the newest of any account. An own
  item that holds no Claude credential still wins (counts as empty, logged): only a missing own
  item opens other accounts. The `security` shell-out ranks own items per search-list keychain
  (one keychain can't hold two items with the same service and account); with no own item it
  ranks every account from `security dump-keychain` (attributes only), run only when the
  service has some item. Match the `svce` line whole: the bare service name prefixes every
  hashed one. A clean `security` read never falls back to SecItem (that only adds a prompt).
- Usage-cost from local logs: Claude jsonl repeats the **same** `usage` on every content-block line
  of a message — dedupe by `(message.id, requestId)` when summing or the estimate ~doubles. Codex
  sums `last_token_usage` deltas, never the cumulative `total_token_usage`. (`LogCostScanner` +
  `Claude`/`CodexLogCostReader`.)
- Cursor usage comes from undocumented `cursor.com/api/usage-summary` (cookie
  `WorkosCursorSessionToken=<sub after "|">%3A%3A<token>`). The billing cycle rides in the
  **session** slot as scoped `api`/`auto` pool windows with `startsAt` + `periodLabel: "mo"`
  (`totalPercentUsed` is a size-weighted average that hides a full API pool; fallback only);
  `limit`/`used` are cents. Grok Bot's
  weekly limit is NOT in that response: it comes from Connect RPC
  `POST api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus` (Bearer token, body `{}`)
  and rides in the **weekly** slot labelled "Grok"; a failure there leaves the monthly reading up.
- A PostToolUse hook lints every edited `.swift` with `swiftlint --strict`, so default warnings
  (cyclomatic_complexity >10, function_body_length >50, parameter_count >5, large_tuple) **fail the
  edit** — keep functions small, or add an inline `// swiftlint:disable:this <rule>` (existing
  convention; see `LogCostScanner`, `UsageStore`).
