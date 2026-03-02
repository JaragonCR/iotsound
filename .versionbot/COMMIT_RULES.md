# Commit Message Guidelines

This project uses [Versionist](https://github.com/product-os/versionist) to automatically
generate changelogs and bump versions based on commit messages.

## Format

Every commit that should trigger a version bump must include a `Change-type` footer:

```
<type>: <short description>

<optional longer description>

Change-type: patch | minor | major
```

## Change types

| Type | When to use | Version bump |
|---|---|---|
| `patch` | Bug fixes, dependency updates, documentation | 4.0.0 → 4.0.1 |
| `minor` | New features, backward-compatible improvements | 4.0.0 → 4.1.0 |
| `major` | Breaking changes, major rewrites | 4.0.0 → 5.0.0 |

## Examples

```
fix: correct PulseAudio sink name for HiFiBerry DAC

Change-type: patch
```

```
feat: add karaoke support via pitube-karaoke

Change-type: minor
```

## Branches

- All work should be done on feature branches
- PRs merged to master trigger Versionist
- Versionist opens a version bump PR automatically
- Merge the version bump PR to create a tagged release
