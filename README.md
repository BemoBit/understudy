# Understudy

**Keep your expensive model for thinking. Send the reading and the boilerplate to a cheap one.**

Understudy is a [Claude Code](https://claude.com/claude-code) plugin. It stops
your main model from pouring large files into its own context, and routes that
work to a Haiku worker instead. The worker reads the files; your model gets the
answer.

No API key. No account. No external service. The delegation runs through the
`claude` CLI you already have, on the authentication you already use.

📖 [راهنمای فارسی](README.fa.md)

---

## The problem

A 1,000-line file is roughly 13,000 tokens. Read it once and it sits in your
context for the rest of the session — re-sent, and re-billed, on every
subsequent turn. Read four of them and half the window is gone before the
actual work starts.

Most of those tokens are not what your model is good at. "Which functions touch
the database?" does not need frontier reasoning. It needs someone to read the
file.

## The solution

Three layers, from hard gate to soft suggestion:

| Layer | What it does |
|---|---|
| **Hooks** | Refuse `Read` on files over 350 lines, and `cat`/`less` on the same, pointing at the delegate instead |
| **Scripts** | Carry the delegation: build the prompt, invoke the worker, clean up the output |
| **Skills** | Tell the agent when and how to call the scripts |

Your model never assembles a shell pipeline from prose. It calls a script with
named arguments, and the script handles the rest.

```bash
bulk-read --question "Which methods write to the database?" --paths src/UserService.java
```

The file goes to the worker. The answer comes back. Your context holds the
answer, not the file.

---

## Requirements

- **Claude Code CLI** — already installed if you are reading this
- **[jq](https://jqlang.org)** — `brew install jq` / `apt install jq`

That is the whole list. macOS and Linux, `bash` 3.2 and up. Nothing is
installed globally, nothing runs in the background, nothing phones home.

## Install

```bash
claude plugin marketplace add BemoBit/understudy
claude plugin install understudy@understudy
```

Start a new session and check the setup:

```text
/understudy:doctor
```

That runs a read-only health check. To also prove a real delegation round trip
— authentication, model access, the lot — for about a tenth of a cent, ask for
`/understudy:doctor --probe`.

To install from a local clone instead:

```bash
git clone https://github.com/BemoBit/understudy.git
claude plugin marketplace add ./understudy
claude plugin install understudy@understudy
```

A clone is also the easiest way to run the scripts by hand, since the installed
copy lives under a version-pinned cache path:

```bash
export PATH="$PATH:$HOME/understudy/plugins/understudy/scripts"
understudy-doctor --probe
```

### What it costs you in context

```
Always-on:   ~284 tokens added to every session
```

Three skill descriptions. The hooks run in the harness and cost nothing at all.

---

## Usage

### Automatic

Once installed, the hooks do the work. Your model tries to read a 900-line
file, the hook refuses and names the alternative, and the model delegates. You
do not have to ask for any of it.

### Manual

Both scripts are ordinary CLI tools. Run them yourself:

```bash
bulk-read --question "<question>" --paths <file> [<file> ...]

  --question <text>     What to ask about the files (required)
  --paths <file...>     Files to send (required; text files only)
  --mode <name>         Worker mode / system prompt (default: bulk-reader)
  --model <name>        Override the delegate model for this call
  --no-line-numbers     Send raw content instead of numbered lines
```

```bash
code-write --spec "<what to build>" --reference <file> [--target <path>]

  --spec <text>         What to generate (required)
  --reference <file>    File whose patterns the output must match
                        (required, repeatable)
  --target <path>       Write here instead of stdout
  --force               Allow --target to overwrite an existing file
  --mode <name>         Worker mode / system prompt (default: code-writer)
  --model <name>        Override the delegate model for this call
```

Examples:

```bash
# One question across three files
bulk-read --question "How does a request get from the router to the database?" \
          --paths src/router.ts src/controller.ts src/repo.ts

# Generate a test that matches an existing one
code-write --spec "Tests for UserService covering the failure paths" \
           --reference tests/OrderServiceTest.java \
           --target tests/UserServiceTest.java
```

### Each call is one shot

Nothing is remembered between calls. To follow up, ask again with the same
`--paths`. Re-sending the corpus is free where it matters: it goes to the
worker, never to you.

---

## Configuration

Every setting is an environment variable. For a project, put them in the `env`
block of `.claude/settings.json`; for everything you do, in
`~/.claude/settings.json`.

```json
{
  "env": {
    "UNDERSTUDY_MIN_LINES": "500",
    "UNDERSTUDY_LOG": "/Users/you/.understudy.jsonl"
  }
}
```

| Variable | Default | What it does |
|---|---|---|
| `UNDERSTUDY_MODEL` | `claude-haiku-4-5-20251001` | The worker model |
| `UNDERSTUDY_BULK_READER_MODEL` | — | Model for the bulk-reader mode only |
| `UNDERSTUDY_CODE_WRITER_MODEL` | — | Model for the code-writer mode only |
| `UNDERSTUDY_MIN_LINES` | `350` | Line count above which the hooks refuse a read |
| `UNDERSTUDY_DISABLE` | unset | Set to anything to switch the hooks off |
| `UNDERSTUDY_TIMEOUT_SECONDS` | `180` | Watchdog on one delegation |
| `UNDERSTUDY_MAX_INPUT_TOKENS` | `150000` | Refuse a request bigger than this |
| `UNDERSTUDY_MODES_DIR` | — | Extra directory to look for mode prompts in |
| `UNDERSTUDY_CLAUDE_BIN` | `claude` | How to launch the CLI |
| `UNDERSTUDY_LOG` | — | Append one JSONL record per delegation |

A per-mode model beats `UNDERSTUDY_MODEL`, and `--model` on the command line
beats both. Generation is harder than reading, so pointing the code writer at a
mid-tier model while the reader stays on Haiku is a reasonable split:

```json
{ "env": { "UNDERSTUDY_CODE_WRITER_MODEL": "claude-sonnet-5" } }
```

### Custom modes

A *mode* is a system prompt on disk. The two bundled ones live in
`plugins/understudy/modes/`. Drop a file with the same name in
`~/.config/understudy/modes/` and it wins — no fork, no reinstall:

```bash
mkdir -p ~/.config/understudy/modes
cp .../modes/bulk-reader.md ~/.config/understudy/modes/
$EDITOR ~/.config/understudy/modes/bulk-reader.md
```

New modes work the same way. Write `~/.config/understudy/modes/sql-reviewer.md`,
then `bulk-read --mode sql-reviewer --question ... --paths ...`.

---

## What it actually saves

The honest answer: **context is saved for certain, money depends on your
session.**

A measured run on a real 988-line file:

```
[understudy: bulk-reader · claude-haiku-4-5-20251001 · in 13,014 → out 2,622 tok · $0.049 · 17.5s]
```

Those 13,014 tokens never entered the main context, so they were never re-sent
on any later turn — which is where the compounding saving lives. Against that:
the call took 17.5 seconds and cost five cents of its own.

So it pays off when the file is large, when the session is long, and when the
question is a lookup rather than a judgement. It does not pay off on a 200-line
file you are about to edit.

Do not take these numbers on faith. Set `UNDERSTUDY_LOG` and measure your own:

```bash
jq -s 'group_by(.mode)[] | {mode: .[0].mode, calls: length,
       input_tokens: map(.input_tokens) | add,
       usd: map(.cost_usd) | add}' ~/.understudy.jsonl
```

## When not to delegate

The skills tell the agent this, and it is worth knowing yourself:

- **Editing.** An edit needs exact bytes in context. Read the region with
  `offset`/`limit` — targeted reads are never blocked.
- **Debugging.** A summary of the code is not what finds the bug.
- **Small files.** Under the threshold, the round trip costs more than it saves.
- **Design decisions.** Those are why you are paying for the expensive model.

---

## How the delegation works

One `claude -p` call per delegation, deliberately stripped down:

```bash
claude -p \
  --model claude-haiku-4-5-20251001 \
  --system-prompt "<the mode>" \    # replaces the default prompt entirely
  --tools "" \                      # no tool access at all
  --safe-mode \                     # no CLAUDE.md, plugins, hooks or MCP
  --strict-mcp-config \
  --no-session-persistence \
  --output-format json \
  < prompt.txt                      # stdin, so there is no ARG_MAX ceiling
```

Each flag earns its place:

- **`--system-prompt`** replaces the agent system prompt rather than appending
  to it, so the worker carries no scaffolding it will never use.
- **`--tools ""`** leaves the worker no way to act. The corpus is already in the
  prompt, and a worker that cannot act cannot surprise you.
- **`--safe-mode`** is what stops the Read hook from firing *inside* the
  delegate and recursing, and it keeps your `CLAUDE.md` out of a call that has
  no use for it.
- **stdin** is why there is no payload ceiling to work around. The only limit
  is the worker's context window.

### Design decisions worth knowing about

- **The hooks fail open.** No `jq`, no `claude`, no scripts, or
  `UNDERSTUDY_DISABLE` set — the read goes through. A hook that bricks your
  agent when its backend is missing is worse than no hook.
- **The hooks never emit "allow".** They deny or stay silent. An explicit allow
  would auto-approve reads that your permission settings might otherwise ask
  about; silence lets the normal flow continue untouched.
- **Command strings are never evaluated.** The Bash hook splits on whitespace
  with globbing off. Nothing in a command can execute from inside the hook.
- **Binary files are skipped everywhere.** They would reach the worker as
  garbage and come back as a confident answer about nothing.
- **`code-write` will not overwrite.** Pass `--force` if you mean it.
- **The worker can refuse.** Told it cannot satisfy a spec, it answers with a
  bare `ERROR:` line, and the script reports it instead of writing that
  sentence into a source file.
- **Token accounting is honest.** Claude Code caches large prompts and reports
  most of the input under the cache counters, so the stats line sums all three.

---

## Tests

```bash
bash plugins/understudy/evals/run.sh
```

40 cases: 13 for the Read hook, 15 for the Bash hook, 12 for the delegation
transport. They run against a stub `claude` on `PATH`, so they need no
credentials, make no network calls, and cost nothing. CI runs them on both
Ubuntu and macOS on every push.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `missing required command(s): jq` | `brew install jq` or `apt install jq` |
| `The Claude CLI is not authenticated` | `claude auth login` |
| `Model "..." is not available to this account` | Set `UNDERSTUDY_MODEL` to one that is |
| Delegation exceeded the timeout | Raise `UNDERSTUDY_TIMEOUT_SECONDS`, or send fewer files |
| `request is ~N tokens, over the budget` | Split the call, or raise `UNDERSTUDY_MAX_INPUT_TOKENS` |
| Hooks block a file you need whole | Read it in slices with `offset`/`limit`, or set `UNDERSTUDY_DISABLE=1` |
| Hooks do nothing at all | Start a new session; hooks load at session start |

`understudy-doctor` reports all of the above in one pass.

## Uninstall

```bash
claude plugin uninstall understudy
claude plugin marketplace remove understudy
```

Nothing is left behind: no daemon, no cache, no config outside your own
settings file.

---

## Roadmap

- Pluggable delegation backends (direct Anthropic API, local models) behind the
  seam that already exists in `delegate.sh`
- More modes: diff summariser, log analyser, translation
- Hook enforcement for `code-write`, which today relies on the skill description

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports that include the output of
`understudy-doctor` get fixed faster.

## License

[Apache-2.0](LICENSE). The architecture was inspired by the `shunt` plugin in
`spotify/portal-ai-plugins`; see [NOTICE](NOTICE) for the full acknowledgement.
Understudy contains no code from that project and has no dependency on Spotify
Portal, the Portal CLI, or AiKA.
