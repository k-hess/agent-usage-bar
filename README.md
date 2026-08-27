# ClaudeUsageBar

A tiny macOS menu bar app that shows your Claude Code usage limits — the same numbers as `/usage`, without opening a session to check.

<img src="docs/screenshot.png" alt="ClaudeUsageBar in the menu bar with its dropdown open" width="560">

The number in the bar is whichever limit is closest to capping you (max across your session and weekly limits). It shows a ⚠️ when the API flags a limit as elevated, or at 80%+ as a backstop.

## Install

Requires macOS 13+, Xcode Command Line Tools (`xcode-select --install`), and a logged-in [Claude Code](https://claude.com/claude-code).

```sh
git clone https://github.com/k-hess/claude-usage-bar.git
cd claude-usage-bar
make install
```

That builds the app, installs it to `/Applications`, and launches it. No permission prompts, no setup — it reads the token the same way Claude Code itself does.

Turn on **Launch at login** from the dropdown if you want it to survive reboots.

## How it works

- Reads the OAuth token Claude Code already stores in your macOS Keychain, via Apple's `/usr/bin/security` tool — the same path Claude Code uses. (The Keychain item's partition list only trusts Apple-signed tools, so an ad-hoc-signed app reading it directly triggers a keychain password prompt on every poll; going through `security` avoids that.) No separate login, no API key to configure.
- Calls `GET https://api.anthropic.com/api/oauth/usage` — the endpoint behind `/usage` — every 5 minutes, plus on demand via **Refresh now**.
- Renders whichever limits your plan has, straight from the response's `limits` array — session 5h, weekly all-models, and any model-scoped weekly limit (it picks up the model's display name, so a new model shows up without a code change). Falls back to the legacy `five_hour`/`seven_day*` fields if `limits` is absent.
- Shows your extra-usage credit spend (percent, plus dollars used of your monthly limit) when credits are enabled.

If the token expires (401), the bar shows `CC –` with "Token stale — open Claude Code to refresh" in the dropdown. Claude Code rotates the token whenever it runs, so it self-heals the next time you use it.

## Security notes

Worth being explicit, since this app touches your Claude credentials:

- The token is read from the Keychain into memory (via a `/usr/bin/security` subprocess, output captured over a pipe) and sent to exactly one place: `api.anthropic.com`, over HTTPS, in the `Authorization` header.
- It is never logged, never written to disk, never placed in a URL.
- There is no telemetry, no analytics, and no other network call. The whole app is one Swift file — [read it](Sources/ClaudeUsageBar/main.swift).

## Icon

`Icon/AppIcon.icns` is checked in. To change it, edit and re-run `Icon/make-icon.sh` (needs `brew install imagemagick`), then `make install`.

## Uninstall

```sh
make uninstall
```

## License

[MIT](LICENSE)
