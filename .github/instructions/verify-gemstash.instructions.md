---
applyTo: "lib/**,bin/**,exe/**,gemstash.gemspec,Gemfile,.agents/skills/verify-gemstash/**"
excludeAgent: "cloud-agent"
---

# Prove server and CLI changes with verify-gemstash

- Read `.agents/skills/verify-gemstash/SKILL.md`, then `.agents/skills/verify-gemstash/features/INDEX.md`, and drive every recipe that INDEX.md routes the changed files to with the skill's helper.
- The review environment already has Ruby, the bundle, and `lsof` for the helper, installed by `.github/workflows/copilot-code-review.yml`.
- For each `fail` that does not match a `Known failure` entry in Gotchas, comment on the changed lines most likely responsible, with the sub-feature ID and the expected result.
- When a bullet with a `Known failure` entry meets its `Expected:` result and the pull request keeps the entry, comment on the changed lines most likely responsible and name the Gotchas entry to delete.
- Quote the observed output lines wherever you report a `fail`, because readers of the review cannot open the evidence files.
- If the helper cannot run, review the diff against those recipes' stated results and Gotchas instead, and say in the review which sub-feature IDs you did not drive and the error that stopped them.
- Call a sub-feature verified only when you drove it and its evidence matches the recipe.
- When the diff changes a result that a feature file states, or adds user-facing behavior that no recipe covers, and leaves the feature files unchanged, comment on the change and name the feature file to update.
