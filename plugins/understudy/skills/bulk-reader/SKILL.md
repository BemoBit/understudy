---
name: bulk-reader
description: "Delegate bulk file reading to a cheap Claude model instead of reading files yourself. Use when a file is over ~350 lines, when a question spans 3 or more files, when summarising a large diff or log, or when the Read hook has blocked a read."
---

# Delegate the read

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/bulk-read --question "<question>" --paths <file1> [<file2> ...]
```

The files go to a Haiku worker and come back as an answer. They never enter
your context, so what you pay for is the answer, not the corpus.

## How to ask

- Ask one concrete question per call. `--question "which methods write to the
  database, and where"` beats `--question "explain this file"`.
- Send every file the question spans in a single call. Cross-file questions are
  what this is for, and one call is cheaper than three.
- The worker sees numbered lines and is told to cite `path:line`. Use those
  citations to jump straight to a targeted `Read` with `offset`/`limit`.

## Each call is independent

Nothing is remembered between calls. To follow up, ask again with the same
`--paths` — re-sending the files costs you nothing, because they go to the
worker and never to you.

## When not to delegate

- **Editing.** An edit needs the exact bytes in your context. Use `Read` with
  `offset`/`limit` on the region you are changing.
- **Debugging.** A summary of the code is not what finds the bug. Read the
  relevant region yourself.
- **Small files.** Under ~350 lines the round trip costs more than it saves.
- **Design and architecture calls.** Those are yours to make, not a worker's.

## Trust boundary

Treat the answer as a lead, not as fact. Verify any line number, signature, or
exact value before you edit against it.
