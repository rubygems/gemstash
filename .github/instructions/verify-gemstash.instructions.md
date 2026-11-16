---
applyTo: "lib/**,bin/**,exe/**,gemstash.gemspec,Gemfile,.agents/skills/verify-gemstash/**"
excludeAgent: "cloud-agent"
---

# Prove server and CLI changes with verify-gemstash

This pull request changes code that the `gemstash` CLI or its gem server runs, or the verify-gemstash skill itself. Review its user-facing behavior with that skill: read `.agents/skills/verify-gemstash/SKILL.md`, then `.agents/skills/verify-gemstash/features/INDEX.md`, which routes each changed file to the feature recipes it reaches. The skill owns how to launch, drive, judge, report, and clean up; where these notes and the skill differ, follow the skill.

- Drive every routed recipe with the skill's helper from the repository root. The review environment installs Ruby, the bundle, and `lsof` for it through `.github/workflows/copilot-code-review.yml`. A bullet whose observed result differs from the result its recipe states is a finding: comment on the changed lines most likely responsible, with the sub-feature ID, the expected result, and the output lines you observed, because people reading the review cannot open your evidence files.
- When the helper cannot run, such as no shell, `no Ruby found`, `bundle is incomplete`, a launch that never reports healthy, or a mirror step blocked by the network, review the diff against each routed recipe's stated results and Gotchas instead. Say in the review which sub-feature IDs you did not drive and the error that stopped them. Call a sub-feature verified only when you drove it and its evidence matches the recipe.
- When the diff changes a result that a recipe states, or adds user-facing behavior that no recipe covers, and the pull request leaves the feature files unchanged, comment on the change and name the feature file that needs updating.
