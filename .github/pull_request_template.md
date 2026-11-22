## What changes

<!-- What this pull request changes and why. Link the issue or the backend change, if any. -->

## How it was tested

<!-- The commands you ran and their result, for example: bundle exec rake spec codegen:spec,
bundle exec rake rubocop, bundle exec steep check, bundle exec rake generate:check. -->

## Checklist

- [ ] Conventional commit title whose type matches the semver impact (`fix` patch, `feat` minor, `feat!` or `BREAKING CHANGE:` major, minor while 0.x)
- [ ] Tests for every behaviour change
- [ ] README updated for public API changes
- [ ] Generated code regenerated with `bundle exec rake generate`, never edited by hand
- [ ] No secrets, real API keys or customer data (test webhook secrets start with `whsec_test_`)
- [ ] Parity: same change in the other six SDK repositories, or not applicable because ...
