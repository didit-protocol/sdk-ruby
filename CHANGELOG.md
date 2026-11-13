# Changelog

## [2.15.0](https://github.com/didit-protocol/sdk-ruby/compare/v2.14.0...v2.15.0) (2026-11-13)


### Features

* **spec:** sync API spec 2026-11-13 ([9668e12](https://github.com/didit-protocol/sdk-ruby/commit/9668e1273ce001ec5208334bf1fa1fd61f9ebe51))

## [2.14.0](https://github.com/didit-protocol/sdk-ruby/compare/v2.13.1...v2.14.0) (2026-11-12)


### API changes that can break typed code

* **spec:** `cases.blueprints.publish` (`POST /v3/organization/{organization_id}/application/{application_id}/cases/blueprints/{blueprint_uuid}/publish/`): response `content_config`: type changed from any to object ([f28c0c9](https://github.com/didit-protocol/sdk-ruby/commit/f28c0c91f98e2d6081605397792d6af844c0939b))
* **spec:** `cases.create` (`POST /v3/organization/{organization_id}/application/{application_id}/cases/`): request body `links[].entity_type`: added (required) ([f28c0c9](https://github.com/didit-protocol/sdk-ruby/commit/f28c0c91f98e2d6081605397792d6af844c0939b))
* **spec:** `cases.create` (`POST /v3/organization/{organization_id}/application/{application_id}/cases/`): request body `links[].entity_uuid`: added (required) ([f28c0c9](https://github.com/didit-protocol/sdk-ruby/commit/f28c0c91f98e2d6081605397792d6af844c0939b))


### Features

* **spec:** sync API spec 2026-11-12 ([f28c0c9](https://github.com/didit-protocol/sdk-ruby/commit/f28c0c91f98e2d6081605397792d6af844c0939b))

## [2.13.1](https://github.com/didit-protocol/sdk-ruby/compare/v2.13.0...v2.13.1) (2026-11-12)


### Bug Fixes

* **authentication:** a body nested past the depth limit is not JSON ([c0cb38e](https://github.com/didit-protocol/sdk-ruby/commit/c0cb38edf6f8302c640bfac2bac2e8191b3c123f))
* **authentication:** a failure to encode a consent request has a fixed message ([2f2bdb7](https://github.com/didit-protocol/sdk-ruby/commit/2f2bdb7302fb6b56db5b1b29cd90cf447ef588a5))
* **authentication:** a malformed 2xx consent error keeps no parser exception as its cause ([e9cad91](https://github.com/didit-protocol/sdk-ruby/commit/e9cad918b725708f14ee37f5f07922ab78d074be))
* **authentication:** a malformed 2xx consent message reads the content type from the sanitized response ([fa0e897](https://github.com/didit-protocol/sdk-ruby/commit/fa0e897c76d810f473b2f4c69cd6025883ba1ce5))
* **authentication:** collect consent secrets from the JSON the request carries ([ada5949](https://github.com/didit-protocol/sdk-ruby/commit/ada5949ad9afd041cbf8f2766e5889f66600dae7))
* **authentication:** read consent secrets from the bytes that were sent ([02a0be4](https://github.com/didit-protocol/sdk-ruby/commit/02a0be4ef2688595a66aeda5f03e512f20109b94))
* **authentication:** redact every string of the consent assertion from errors ([c1ed630](https://github.com/didit-protocol/sdk-ruby/commit/c1ed63076c21fd9a66939045b026bb68592ad580))
* **authentication:** redact the parsed agent-consent response, not its raw text ([9d8dfef](https://github.com/didit-protocol/sdk-ruby/commit/9d8dfef87e9c2d2f5433551b75de28a98608cd1b))
* **authentication:** sanitize the whole consent response once on receipt ([d7f875d](https://github.com/didit-protocol/sdk-ruby/commit/d7f875deabe3cb4a0311ced9d6bf416a4c7ef19d))
* **authentication:** successful consent responses reach the caller unchanged; fold header-name case ([9becd6d](https://github.com/didit-protocol/sdk-ruby/commit/9becd6d166d122deeec244248890a0a4f5c8b847))
* **authentication:** the approval-options call encodes through the same fixed-message wrapper ([570043e](https://github.com/didit-protocol/sdk-ruby/commit/570043e36c63e494708c2f7cc8ab0ae412633c1f))
* **authentication:** treat only assertion strings of 16+ characters as secrets ([e072900](https://github.com/didit-protocol/sdk-ruby/commit/e072900a01bb52e865159ef88811c2398bd442e2))
* **authentication:** withhold transport causes, redact empty bodies, headers and request id, keep safe key names ([d966dc2](https://github.com/didit-protocol/sdk-ruby/commit/d966dc27fe9dcc0909446272961258cdb22178fb))

## [2.13.0](https://github.com/didit-protocol/sdk-ruby/compare/v2.12.0...v2.13.0) (2026-11-11)


### Features

* **spec:** sync API spec 2026-11-11 ([918c23f](https://github.com/didit-protocol/sdk-ruby/commit/918c23f87009d9d61c568fc270fd97a17b0aa2b0))

## [2.12.0](https://github.com/didit-protocol/sdk-ruby/compare/v2.11.0...v2.12.0) (2026-11-11)


### Features

* **spec:** sync API spec 2026-11-11 ([99ec1de](https://github.com/didit-protocol/sdk-ruby/commit/99ec1de70b9b7741f5c3fce5e423b55d8e34d86e))

## [2.11.0](https://github.com/didit-protocol/sdk-ruby/compare/v2.10.0...v2.11.0) (2026-11-11)


### Features

* **spec:** sync API spec 2026-11-11 ([8583597](https://github.com/didit-protocol/sdk-ruby/commit/85835972757c41b3b5064740c5b70d8da5633404))
* **spec:** sync API spec 2026-11-11 ([cc2310f](https://github.com/didit-protocol/sdk-ruby/commit/cc2310fc48ddd062481703c4760227fe31105105))
* **spec:** sync API spec 2026-11-11 ([dd254dc](https://github.com/didit-protocol/sdk-ruby/commit/dd254dc3c4d46b601b6e64669f452216fc3a1115))
* **spec:** sync API spec 2026-11-11 ([7c675d5](https://github.com/didit-protocol/sdk-ruby/commit/7c675d5ed4adbdb6443bb765bdd2fb164004a907))
* **spec:** sync API spec 2026-11-11 ([4e1b076](https://github.com/didit-protocol/sdk-ruby/commit/4e1b07650dfc74f5ad69dfb7668051e76af0c31d))

## [2.10.0](https://github.com/didit-protocol/sdk-ruby/compare/v2.9.0...v2.10.0) (2026-11-11)


### Features

* **spec:** sync API spec 2026-11-11 ([f2e8649](https://github.com/didit-protocol/sdk-ruby/commit/f2e8649be2f8bee51ee031917d56ad4a2d31d345))

## [2.9.0](https://github.com/didit-protocol/sdk-ruby/compare/v2.8.0...v2.9.0) (2026-11-10)


### Features

* **spec:** sync API spec 2026-11-10 ([96b48e5](https://github.com/didit-protocol/sdk-ruby/commit/96b48e595d53fda32caf3853e73782bf6a580769))

## [2.8.0](https://github.com/didit-protocol/sdk-ruby/compare/v2.7.0...v2.8.0) (2026-11-10)


### Features

* **spec:** sync API spec 2026-11-10 ([b109fe6](https://github.com/didit-protocol/sdk-ruby/commit/b109fe66dfe21bdb989af8df44011ef0bcb9027b))

## [2.7.0](https://github.com/didit-protocol/sdk-ruby/compare/v2.6.0...v2.7.0) (2026-11-10)


### Features

* **spec:** sync API spec 2026-11-10 ([e0fd230](https://github.com/didit-protocol/sdk-ruby/commit/e0fd2304137818d95f794b3cff42ddb8c405ca0e))

## [2.6.0](https://github.com/didit-protocol/sdk-ruby/compare/v2.5.0...v2.6.0) (2026-11-10)


### Features

* **spec:** sync API spec 2026-11-10 ([bd9dcb0](https://github.com/didit-protocol/sdk-ruby/commit/bd9dcb09fe8a2ae28e0c9fc16fdd0d9f168fa9ac))

## [2.5.0](https://github.com/didit-protocol/sdk-ruby/compare/v2.4.0...v2.5.0) (2026-11-10)


### Features

* **spec:** sync API spec 2026-11-10 ([8d93d58](https://github.com/didit-protocol/sdk-ruby/commit/8d93d5847af771aeaac516b40c20b51913ed5f7b))

## [2.4.0](https://github.com/didit-protocol/sdk-ruby/compare/v2.3.0...v2.4.0) (2026-11-10)


### Features

* **spec:** sync API spec 2026-11-10 ([3d9140b](https://github.com/didit-protocol/sdk-ruby/commit/3d9140b30d257e4a40b96de5fbf36b4b218ae0b6))

## [2.3.0](https://github.com/didit-protocol/sdk-ruby/compare/v2.2.0...v2.3.0) (2026-11-09)


### Features

* **spec:** sync API spec 2026-11-09 ([d585311](https://github.com/didit-protocol/sdk-ruby/commit/d58531172dd529b501fdd2071f4b764dec2ca7b7))

## [2.2.0](https://github.com/didit-protocol/sdk-ruby/compare/v2.1.2...v2.2.0) (2026-11-09)


### Features

* **spec:** sync API spec 2026-11-09 ([588db3d](https://github.com/didit-protocol/sdk-ruby/commit/588db3d2b4ed0e1ef0e141d1b52ec20fa7feb28b))

## [2.1.2](https://github.com/didit-protocol/sdk-ruby/compare/v2.1.1...v2.1.2) (2026-11-07)


### API Spec Updates

* **spec:** sync API spec 2026-11-07 ([2a75a53](https://github.com/didit-protocol/sdk-ruby/commit/2a75a5351502a982285b2588f9c95d696ececb0c))
* **spec:** sync API spec 2026-11-07 ([d8b0851](https://github.com/didit-protocol/sdk-ruby/commit/d8b08515b4c0b773f0f5003c8f4cd9eb41558632))

## [2.1.1](https://github.com/didit-protocol/sdk-ruby/compare/v2.1.0...v2.1.1) (2026-11-06)


### API Spec Updates

* **spec:** sync API spec 2026-11-06 ([f8f754d](https://github.com/didit-protocol/sdk-ruby/commit/f8f754de2ebf64b106e4d4936243e2f72d39f0f1))
* **spec:** sync API spec 2026-11-06 ([92a13b6](https://github.com/didit-protocol/sdk-ruby/commit/92a13b6bce036a7100e46cc51d3c6fa95d9ca729))

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
