---
name: reinstall
description: Rebuild AgentBar, reinstall to /Applications, and relaunch it for a live check. Use after code changes to verify behavior in the real menu bar app, or when the user asks to reinstall/relaunch AgentBar.
---

Rebuild and relaunch the installed app:

```bash
killall AgentBar 2>/dev/null; make install && open /Applications/AgentBar.app
```

`make install` only rebuilds when a Swift source or `Package.swift` changed.

**Keychain prompts should NOT appear:** Claude credentials are read via Apple-signed
`/usr/bin/security` (silent), with SecItem only as fallback. If an "AgentBar wants to
access …" prompt shows up, that's a regression in the silent read path — investigate,
don't just tell the user to click Always Allow.

Then ask the user to confirm in the menu bar:

1. The ◆ status icon appears (and reflects overall state, not `!` unless something is wrong).
2. The dropdown lists all configured accounts with plausible usage percentages.
3. Expired/stale accounts show their hint text rather than an error row.
4. Settings opens from the dropdown and lists the discovered accounts.

This skill verifies the live app only — run `swift test` and `swiftlint lint --quiet`
separately for the code-level checks.
