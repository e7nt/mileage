# mileage

A macOS menu bar gauge for your AI coding quotas — Claude Code, Codex, and DeepSeek and
OpenRouter credit, at a glance, like the battery icon.

```
  C 90%   X 25%   D $14   OR $14.20
```

One number per provider showing what's **left**, coloured only when it starts to matter.
Click for the full breakdown: every quota window, how much is left, and when it resets.

**Multiple accounts per provider.** Two Claude logins, three ChatGPT accounts — each polled
independently, each with its own quota. The menu bar still shows one number per provider: the
worst account, because that's the one about to stop you. A `·` after a number means there are
more accounts behind it. This is the thing existing menu bar trackers don't do, and the reason
mileage exists alongside [CodexBar](https://github.com/steipete/CodexBar).

Providers you haven't set up don't appear in the bar at all — it reports what you have rather
than advertising what you don't. Add them from the popover.

**Pick your own letters.** `C`, `X`, `D` and `OR` are only defaults. Set anything you like per
provider in Settings — initials, symbols, emoji — up to three characters. Clearing the field
restores the default, so you can't get stuck with a blank. mileage ships no company logos
deliberately: those are trademarks, and bundling them in an MIT repo is a fight nobody needs.

**Choose how much the bar shows.** The popover always holds everything; this only decides what
earns menu bar width.

| Setting | Example | Shows |
|---|---|---|
| Tightest limit *(default)* | `C 4%·  X 23%` | One number per provider: whatever runs out first, across every account and window |
| One per account | `C 4% 45%  X 23%` | Each account's tightest window |
| Every window | `C 90%\|4% 45%\|80%  X 23%\|100%` | Everything, accounts separated by space, windows by `\|` |

"Tightest" compares **all** windows, not just the session one — a Claude account with 4% of its
weekly limit left surfaces as `4%`, even while its 5-hour window sits at a comfortable 90%.

DeepSeek shows the spendable total only. The granted/topped-up split is an accounting detail,
not something a menu bar should spend a line on. OpenRouter reports lifetime purchased and
lifetime spent rather than a balance, so mileage shows the difference — and shows it negative
if you're overdrawn, because that's the one state worth acting on.

## Install

Requires macOS 14+.

```sh
git clone https://github.com/<you>/mileage.git
cd mileage
make run
```

`make run` builds a release binary, assembles `Mileage.app`, ad-hoc signs it, and launches it.
A Homebrew cask will follow once releases are notarized.

## First run

Nothing to configure for Claude and Codex — mileage adopts whatever the CLIs are already signed
into. macOS will ask once for permission to read Claude Code's Keychain item.

## Adding more accounts

**Accounts…** in the popover opens the account manager.

- **Codex** — "Sign in with ChatGPT" opens your browser and returns on its own. Quit any running
  `codex login` first; both need port 1455.
- **Claude** — opens Anthropic's sign-in, which shows you a `code#state` value to paste back.
  Anthropic redirects to a page mileage doesn't control, so there's no callback to catch; this is
  the same fallback Claude Code itself uses. Give the account a name — Anthropic's usage API
  doesn't report *which* account it is, so a name is the only way to tell two apart.
- **DeepSeek** — paste a key from
  [platform.deepseek.com](https://platform.deepseek.com/api_keys).
- **OpenRouter** — paste a key from
  [openrouter.ai/settings/keys](https://openrouter.ai/settings/keys) that's allowed to read your
  credits. A key without that access is rejected with an explanation rather than a generic
  sign-in error.

API keys are validated before they're saved, so a bad key fails immediately rather than silently
at the next poll.

Everything goes to the Keychain. Accounts you add have their own OAuth grant that mileage owns
and refreshes; imported CLI accounts stay strictly read-only. See [SECURITY.md](SECURITY.md).

## Debugging

```sh
./Mileage.app/Contents/MacOS/Mileage --once
```

Polls every provider once, prints what the menu bar would show, and exits.

```
Claude Code (2 account(s)) → bar shows 45%
  work [oauth]
    * 5h: 45% left · resets in 3h 27m
      weekly: 70% left · resets in 1d 0h
  signed in via CLI [cli]
    * 5h: 88% left · resets in 1h 02m
Codex (1 account(s)) → bar shows 25%
  someone@example.com [cli]
    * weekly: 25% left · resets in 2d 14h
```

## Where the numbers come from

| Provider | Source |
|---|---|
| Claude Code | `GET api.anthropic.com/api/oauth/usage` — the same data behind `/usage` |
| Codex | `GET chatgpt.com/backend-api/wham/usage` — the same endpoint the Codex CLI polls |
| DeepSeek | `GET api.deepseek.com/user/balance` — the documented balance API |
| OpenRouter | `GET openrouter.ai/api/v1/credits` — the documented credits API |

**The Claude and Codex endpoints are undocumented internal APIs**, reached with the CLIs' own
public OAuth client IDs. They can change or disappear without notice, and using them this way
is a grey area under those providers' terms. The DeepSeek and OpenRouter endpoints are
supported public APIs. Nothing here bypasses a limit or a payment — it only reads what the CLIs already show you.

### Polling

Anthropic's usage endpoint rate-limits aggressively
([1](https://github.com/anthropics/claude-code/issues/31021),
[2](https://github.com/anthropics/claude-code/issues/31637)), so mileage is deliberately
unhurried: Claude every 5 minutes, Codex every 3, DeepSeek and OpenRouter every 15 — **per
account**, each
jittered ±20% so several accounts never stampede the same endpoint together, with exponential
backoff to an hour on 429 and manual refresh throttled to once per 30 seconds.
The `User-Agent: claude-code/<version>` header is required to stay out of the punitive bucket.

## Privacy

- Tokens and API keys live in the macOS Keychain. Nothing is written to disk in plaintext.
- No telemetry, no analytics, no crash reporting, no phoning home.
- The only hosts contacted are `api.anthropic.com`, `chatgpt.com`, `api.deepseek.com`, and
  `openrouter.ai`.
- mileage **never writes to your CLI credential files and never refreshes their tokens** — both
  providers rotate refresh tokens, and doing so could sign you out of the tool you actually
  work in. See [SECURITY.md](SECURITY.md).

## Development

```sh
swift test     # parser tests, driven by captured real responses
make app       # build the bundle
make lint      # swiftformat + swiftlint
```

`MileageCore` holds all the logic and has no UI dependency, so every provider and formatter is
testable without launching an app. The provider fixtures in `Tests/MileageCoreTests/Fixtures`
are real responses with identifiers replaced — when a provider changes its wire format, update
the fixture first and let the test fail.

## Prior art

[CodexBar](https://github.com/steipete/CodexBar) covers 69 providers and is excellent — use it
if you don't need multiple accounts. [ClaudeBar](https://github.com/tddworks/ClaudeBar) and
[ccusage](https://github.com/ryoppippi/ccusage) are also worth your time; ccusage in particular
does the cost-and-token analytics mileage deliberately doesn't.

## License

MIT
