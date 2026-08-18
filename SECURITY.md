# Security

mileage reads OAuth tokens that grant access to paid AI accounts. This document states exactly
what it does with them.

## What mileage stores, and where

| Secret | Location |
|---|---|
| API keys and OAuth grants mileage obtained itself | macOS Keychain, service `com.e7nt.mileage`, one item per account UUID |
| Claude Code OAuth token (imported account) | **Not stored.** Read from Claude Code's own Keychain item or `~/.claude/.credentials.json` at poll time |
| Codex OAuth token (imported account) | **Not stored.** Read from `~/.codex/auth.json` at poll time |

Account *metadata* — which accounts exist, what you named them, the email a provider reported —
is plain JSON at `~/Library/Application Support/Mileage/accounts.json`. No secret ever enters
that file; there is a test asserting exactly that. Removing an account deletes its Keychain item
in the same operation, so no orphaned secrets are left behind.

Nothing is written to disk in plaintext. Nothing is logged. Tokens exist in memory only for the
duration of a request.

## OAuth scopes

Adding an account uses the CLIs' own public OAuth clients, so mileage must request the scope
sets those clients are registered for:

- **Claude** — `org:create_api_key user:profile user:inference`. mileage only ever calls the
  usage endpoint; it never creates an API key. The scope is present because the client rejects
  narrower requests, not because the app needs it. If you would rather not grant it, use the
  CLI-imported account instead, which mileage reads read-only.
- **Codex** — `openid profile email offline_access`. `offline_access` is what allows mileage to
  refresh its own grant; `email` is what lets it label your accounts.

During a Codex sign-in, mileage listens on `127.0.0.1:1455` — loopback only, never the local
network — for exactly one callback, then stops.

## What mileage will not do

**It never writes to your CLI credential files, and never refreshes their tokens.**

This is the most important safety property. Anthropic and OpenAI both rotate refresh tokens: a
successful refresh can invalidate the token the CLI still holds. A status icon quietly signing
you out of Claude Code or Codex would be a far worse outcome than a stale reading, so mileage
declines to refresh credentials it does not own. Credentials are re-read on every poll instead —
the CLI keeps them current through normal use — and an expired token surfaces as a prompt to run
the CLI once.

When multi-account support lands, added accounts will have their own independent OAuth grants
that mileage owns and may safely refresh. Imported CLI accounts will keep the read-only rule.

## Network

The only hosts contacted are:

- `api.anthropic.com`
- `chatgpt.com`
- `api.deepseek.com`

No telemetry, analytics, crash reporting, or update pings beyond an explicit user-initiated
update check. Your usage numbers never leave your machine.

## Undocumented endpoints

The Claude and Codex endpoints are internal APIs used with the CLIs' public OAuth client IDs.
They are not covered by any stability or access guarantee and may break or be withdrawn. mileage
only reads usage data those tools already display to you; it does not bypass limits, alter
quotas, or access anything a signed-in user cannot see.

## Reporting a vulnerability

Please open a private security advisory through GitHub rather than a public issue. Include the
version, macOS version, and reproduction steps. Reports about credential handling, Keychain
scope, or unexpected network destinations are especially welcome.
