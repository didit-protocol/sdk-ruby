# Changelog

## [2.1.0](https://github.com/didit-protocol/sdk-ruby/compare/v2.0.0...v2.1.0) (2026-11-05)


### Features

* **spec:** sync API spec 2026-11-05 (application data location) ([97b7d9c](https://github.com/didit-protocol/sdk-ruby/commit/97b7d9c8568a18f0712050e0f75d1353c78f9ce9))

## [2.0.0](https://github.com/didit-protocol/sdk-ruby/compare/v1.0.1...v2.0.0) (2026-11-05)


### ⚠ BREAKING CHANGES

* **spec:** the API spec sync changes the SDK surface.
    - `sessions.retrieve_decision` (`GET /v3/session/{sessionId}/decision/`): response 200 `signatures[].confirmation.channel`: can now be null
    - `sessions.retrieve_decision` (`GET /v3/session/{sessionId}/decision/`): response 200 `registry_checks[].company.registry_data`: can now be null
    - `sessions.retrieve_decision` (`GET /v3/session/{sessionId}/decision/`): response 200 `registry_checks[].ownership_structure`: can now be null
    - `email.assess_risk` (`POST /v3/email/risk/`): response 200 `email.email_intelligence.reason_codes[]`: type changed from string to object
    - `kyb.select` (`POST /v3/kyb/select/`): response 200 `kyb_registry.registry_data`: can now be null
    - `kyb.list_shareholders` (`POST /v3/kyb/shareholders/`): response 200 `kyb_registry.registry_data`: can now be null
    - `kyb.list_ubos` (`POST /v3/kyb/ubo/`): response 200 `kyb_registry.registry_data`: can now be null
    - `phone.assess_risk` (`POST /v3/phone/risk/`): response 200 `phone.phone_intelligence.reason_codes[]`: type changed from string to object
    - `sessions.import_shared` (`POST /v3/session/import-shared/`): response 201 `signatures[].confirmation.channel`: can now be null
    - `sessions.import_shared` (`POST /v3/session/import-shared/`): response 201 `registry_checks[].company.registry_data`: can now be null
    - `sessions.import_shared` (`POST /v3/session/import-shared/`): response 201 `registry_checks[].ownership_structure`: can now be null
    - `sessions.signatures.validate` (`POST /v3/session/{sessionId}/signatures/{nodeId}/validate/`): response 200 `signatures[].confirmation.channel`: can now be null

### API Spec Updates

* **spec:** sync API spec 2026-11-04 ([5299349](https://github.com/didit-protocol/sdk-ruby/commit/529934919db87731a0d4f4eec5d51e8fd627cac0))
* **spec:** sync API spec 2026-11-04 ([7282245](https://github.com/didit-protocol/sdk-ruby/commit/72822454ca1e4b130fe37d403ef6958ac4701433))
* **spec:** sync API spec 2026-11-05 ([ced5cdf](https://github.com/didit-protocol/sdk-ruby/commit/ced5cdf2388483c754c2d0ecc137be3fa4c15421))
* **spec:** sync API spec 2026-11-05 ([d0444ca](https://github.com/didit-protocol/sdk-ruby/commit/d0444caa414fe0cd5404e4241d9e57081adcb07e))

## [1.0.1](https://github.com/didit-protocol/sdk-ruby/compare/v1.0.0...v1.0.1) (2026-10-29)


### Miscellaneous Chores

* release 1.0.1 ([2fc666a](https://github.com/didit-protocol/sdk-ruby/commit/2fc666aabf3f664137341bd05590c44060117632))

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
