---
name: dmux-project-conventions
description: Use when making user-facing changes in dmux. Covers project-wide delivery rules such as localization completeness, changelog updates, scoped commits, and avoiding partial UI copy changes.
---

# Dmux Project Conventions

Use this skill for general dmux product work that is not limited to a single subsystem.

## Localization rule

This app is multilingual.

- Any newly added user-facing text must be added to `Sources/DmuxWorkspace/Resources/Localizable.xcstrings`.
- Do not leave new UI copy relying only on `defaultValue`.
- When adding or renaming a localization key, fill every supported locale already present in the project:
  - `en`
  - `zh-Hans`
  - `zh-Hant`
  - `de`
  - `es`
  - `fr`
  - `ja`
  - `ko`
  - `pt-BR`
  - `ru`
- If a view shows duplicated copy because both a container and a control render labels, fix the control usage instead of hiding the problem with layout hacks.

## Change discipline

- Any user-facing feature or bug fix should update both `CHANGELOG.md` and `CHANGELOG.zh-CN.md` under `## [Unreleased]`.
- Keep commits scoped to the finished change.
- Do not push half-verified UI changes as if they were complete.

## Release workflow

When the task touches release packaging, tags, appcast generation, or release notes, read:

- `references/release-workflow.md`

## Local package workflow

`libghostty-spm` is maintained in-repo at:

- `Vendor/libghostty-spm`

When a task needs Ghostty package changes, use this flow:

1. Make and validate code changes in `Vendor/libghostty-spm`.
2. Commit and push the package repo first.
3. Update dmux package references to the pushed revision, not just a branch head:
   - `Package.swift`
   - `dmux.xcodeproj/project.pbxproj`
4. Re-resolve packages and ensure both lockfiles point at the same revision:
   - `Package.resolved`
   - `dmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
5. Then rebuild and verify `./dev.sh`.

Rules:

- Do not treat `.xcode-dev/SourcePackages/checkouts/libghostty-spm` as the source of truth.
- Do not leave the main project pinned only to a floating branch if a specific package fix is required for the current change.
- Temporary direct edits in derived package checkouts are acceptable only for short-lived diagnosis, and must be replaced by a real package commit plus revision pin before finishing.

## UI copy discipline

- Prefer short section titles and keep long explanation text in secondary helper copy.
- Reuse existing localization keys only when the meaning is actually the same.
- If a setting is visible in multiple places, keep the wording consistent across menu, settings, dialogs, and release notes.
