# Changelog

## 1.0.0

First release.

- `bulk-read` — delegates reading one or more files to a cheap Claude model and
  returns a cited answer. Line-numbered by default so the citations can be
  verified with a targeted read.
- `code-write` — delegates whole-file generation, matched against reference
  files. Refuses to overwrite without `--force`, strips markdown fences, and
  reports a worker refusal instead of writing it to disk.
- `check-file-size` / `check-bash-read` — PreToolUse hooks that refuse
  whole-file reads over 350 lines and point at the delegate. Both fail open.
- `understudy-doctor` — read-only readiness check, `--probe` for a live round
  trip.
- Three skills: `bulk-reader`, `code-writer`, `doctor`.
- Delegation runs through `claude -p` on the local installation: no API key, no
  external service, no ARG_MAX ceiling.
- 40 offline test cases; CI on Ubuntu and macOS.
