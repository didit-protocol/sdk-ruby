# Security policy

## Reporting a vulnerability

Report vulnerabilities privately. Do not open a public issue, pull request or discussion.

- GitHub private vulnerability reporting: [Report a vulnerability](https://github.com/didit-protocol/sdk-ruby/security/advisories/new) (the **Security** tab of this repository).
- Or email support@didit.me with the subject "Security".

## What to include

- The SDK version (`ruby -e 'require "didit"; puts Didit::VERSION'`) and the Ruby version (`ruby -v`).
- A description of the issue and what an attacker can do with it.
- Steps or a minimal script to reproduce it.
- Any request id, log line or proof of concept that helps.

Never include real API keys, webhook secrets, access or refresh tokens, or personal data. Replace them with placeholders.

## What to expect

We acknowledge every report within three working days, keep you informed while we investigate, and tell you when a fix is released.
Please give us reasonable time to fix the issue before you disclose it publicly.
We are glad to credit you in the advisory if you wish.

## Supported versions

Security fixes go into the latest 0.x minor release of `didit-sdk`.
Before 1.0.0 a minor release may contain breaking changes, so upgrade to the latest 0.x to receive fixes.

## Scope

This policy covers this library: the code in this repository and the `didit-sdk` gem.
Vulnerabilities in the Didit API, the Didit dashboards or other Didit services are welcome too; report them to support@didit.me.

## Handling secrets with this SDK

- Keep the API key (`DIDIT_API_KEY`) and webhook secrets in environment variables or a secret manager, never in source code.
- The SDK never logs the API key, webhook secrets or Authentication tokens. Debug logging (`DIDIT_LOG=debug`) prints the method, path, status, duration and request id only, never bodies, headers or query strings.
- The API key is never part of an error message and is sent only to the configured `base_url`; a pagination link to another origin is refused.
- Verify every webhook with `Didit::Webhooks.verify` on the raw request body before acting on it.
- Authentication tokens are verified offline (ES256 only); call `get_session` before sensitive actions to see revocations immediately.
