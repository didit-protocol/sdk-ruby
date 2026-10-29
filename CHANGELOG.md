# Changelog

## [1.0.0](https://github.com/didit-protocol/sdk-ruby/compare/v0.1.0...v1.0.0) (2026-10-29)


### ⚠ BREAKING CHANGES

* **spec:** the API spec sync changes the SDK surface (nullable fields, removed fields, account.organizations.list returns a page, the session decision response is the SessionDecision component).

### Features

* add bank.account_check (POST /v3/bank/account-check/) and bank_verifications on the decision ([de3a7b8](https://github.com/didit-protocol/sdk-ruby/commit/de3a7b85d29409df6e8a4eeef793c4fbe00a0904))
* **spec:** sync API spec 2026-10-23 ([#4](https://github.com/didit-protocol/sdk-ruby/issues/4)) ([ce9061c](https://github.com/didit-protocol/sdk-ruby/commit/ce9061c3056274319f5ab9325dba5c8439cc048a))
* **spec:** sync API spec 2026-10-27 ([#13](https://github.com/didit-protocol/sdk-ruby/issues/13)) ([a7ab2a9](https://github.com/didit-protocol/sdk-ruby/commit/a7ab2a9624d64dfda1c3fa2fb03cd93605523fee))


### API Spec Updates

* **spec:** sync API spec 2026-10-25 ([#8](https://github.com/didit-protocol/sdk-ruby/issues/8)) ([2e941a5](https://github.com/didit-protocol/sdk-ruby/commit/2e941a58a29b950f066e9d879f77342a715e9cae))
* **spec:** sync API spec 2026-10-29 ([#15](https://github.com/didit-protocol/sdk-ruby/issues/15)) ([468dbfc](https://github.com/didit-protocol/sdk-ruby/commit/468dbfc3137c4a84021ce1f51a04c2a689b668bd))


### Miscellaneous Chores

* release 1.0.0 ([b183cb4](https://github.com/didit-protocol/sdk-ruby/commit/b183cb463fc00c66d15ab6403f2ecb79c58b49a5))
