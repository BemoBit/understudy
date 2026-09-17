---
name: code-writer
description: "Delegate boilerplate generation to a cheap Claude model. Use when writing a file that closely follows an existing one — a test suite mirroring another test, a CRUD module, a DTO or mapper, a migration, a config variant — where the pattern is already established in the repo."
---

# Delegate the boilerplate

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/code-write \
  --spec "<what to build>" \
  --reference <existing-file> [--reference <another>] \
  [--target <path-to-write>]
```

Without `--target` the result goes to stdout. With it, the file is written to
disk and existing files are never overwritten unless you pass `--force`.

## The reference is the contract

`--reference` is required. The worker has no view of the repo beyond what you
send, so the reference file is the only thing keeping the output in the
project's idiom. Pick the closest existing analogue — the neighbouring test,
the sibling module — not a random file of the same language.

Send a second `--reference` when the output has to satisfy two things at once:
the class under test *and* the test style it should follow.

## Build on what you just generated

The worker keeps nothing between calls, but the file it wrote is now a
reference like any other:

```bash
code-write --spec "Now add the edge-case tests" \
  --reference tests/UserTest.java --target tests/UserEdgeCasesTest.java
```

## When not to delegate

- **Novel logic.** Anything where the right answer is a judgement call.
- **Edits to existing files.** This generates whole files; edit with `Edit`.
- **No good reference.** If nothing in the repo resembles the target, write it
  yourself — a worker with no pattern to match invents one.

## Always review

Read what came back before you rely on it, and run the tests or the build.
Generated code that compiles is not the same as generated code that is right.
