# AgentUsageBar

A tiny macOS menu bar app that shows your Claude Code and Codex usage limits — the same numbers as Claude Code's `/usage` and Codex's `/status`, without opening a session to check.

<img src="docs/screenshot.png" alt="AgentUsageBar in the menu bar with its dropdown open" width="560">

The bar shows one number per agent (`CC 34%  CX 19%`): whichever of that agent's limits is closest to capping you. It shows a ⚠️ when the API flags a limit as elevated, or at 80%+ as a backstop. An agent you aren't logged into shows `–` with the reason in the dropdown.

## Install

Requires macOS 13+, Xcode Command Line Tools (`xcode-select --install`), and a logged-in [Claude Code](https://claude.com/claude-code) and/or [Codex CLI](https://github.com/openai/codex).

```sh
git clone https://github.com/k-hess/agent-usage-bar.git
cd agent-usage-bar
make install
```

That builds the app, installs it to `/Applications`, and launches it. No permission prompts, no setup — it reads the tokens the same way each CLI does. If you had the old ClaudeUsageBar installed, `make install` removes it; re-enable **Launch at login** from the new dropdown.

Turn on **Launch at login** from the dropdown if you want it to survive reboots.

## How it works

### Claude Code

- Reads the OAuth token Claude Code already stores in your macOS Keychain, via Apple's `/usr/bin/security` tool — the same path Claude Code uses. (The Keychain item's partition list only trusts Apple-signed tools, so an ad-hoc-signed app reading it directly triggers a keychain password prompt on every poll; going through `security` avoids that.) No separate login, no API key to configure.
- Calls `GET https://api.anthropic.com/api/oauth/usage` — the endpoint behind `/usage` — every 5 minutes, plus on demand via **Refresh now**.
- Renders whichever limits your plan has, straight from the response's `limits` array — session 5h, weekly all-models, and any model-scoped weekly limit (it picks up the model's display name, so a new model shows up without a code change). Falls back to the legacy `five_hour`/`seven_day*` fields if `limits` is absent.
- Shows your extra-usage credit spend (percent, plus dollars used of your monthly limit) when credits are enabled.

If the token expires (401), the bar shows `CC –` with "Token stale — open Claude Code to refresh" in the dropdown. Claude Code rotates the token whenever it runs, so it self-heals the next time you use it.

### Codex

- Reads the ChatGPT OAuth token and account id from `~/.codex/auth.json`, the file Codex CLI writes on `codex login` (mode 0600, no Keychain involved).
- Calls `GET https://chatgpt.com/backend-api/wham/usage` — the endpoint behind `/status` — on the same 5-minute cycle.
- Renders the plan's primary and secondary rate-limit windows (labelled by window length, e.g. `Session (5h)` and `Week`), plus any separately metered model limits under their own name. Shows your credit balance when you have credits.

If the token expires, the bar shows `CX –` with "Token stale — run codex to refresh". If there's no `auth.json`, it says so and the Claude Code half keeps working.

## Security notes

Worth being explicit, since this app touches your Claude and ChatGPT credentials:

- The Claude token is read from the Keychain into memory (via a `/usr/bin/security` subprocess, output captured over a pipe) and sent to exactly one place: `api.anthropic.com`. The Codex token is read from `~/.codex/auth.json` into memory and sent to exactly one place: `chatgpt.com`. Both over HTTPS, in the `Authorization` header.
- Neither is ever logged, written to disk, or placed in a URL.
- There is no telemetry, no analytics, and no other network call. The whole app is one Swift file — [read it](Sources/AgentUsageBar/main.swift).

## Icon

`Icon/AppIcon.icns` is checked in. To change it, edit and re-run `Icon/make-icon.sh` (needs `brew install imagemagick`), then `make install`.

## Uninstall

```sh
make uninstall
```

## License

[MIT](LICENSE)
