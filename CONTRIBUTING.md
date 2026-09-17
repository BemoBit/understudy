# Contributing

Thanks for looking. Understudy is small on purpose, so the bar for adding
things is high and the bar for fixing things is low.

## Running the tests

```bash
bash plugins/understudy/evals/run.sh
```

40 cases, no network, no credentials, no cost — they run against a stub
`claude` on `PATH`. If your change touches a hook or a script, it needs a case
here, and the case has to fail before your fix and pass after it.

Run it once in a stripped environment too. The hooks fail open when `claude` is
missing, so a suite that leans on your own installation passes locally and
denies nothing on a clean machine:

```bash
env -i HOME="$HOME" PATH=/usr/bin:/bin bash plugins/understudy/evals/run.sh
```

```bash
shellcheck -s bash --severity=warning \
  plugins/understudy/scripts/* plugins/understudy/scripts/lib/*.sh \
  plugins/understudy/hooks/check-* plugins/understudy/evals/run.sh
```

CI runs both on Ubuntu and macOS.

## Working on it locally

```bash
claude plugin marketplace add .
claude plugin install understudy@understudy
# after editing:
claude plugin marketplace update understudy
```

Hooks and skills load at session start, so start a new session to see changes.

## House rules for the code

- **Portable shell.** macOS ships `bash` 3.2 and no `timeout(1)`, and BSD `sed`
  cannot write `\n` in a replacement. Assume all three. `mapfile`, associative
  arrays, `${var,,}` and GNU-only flags are out.
- **Hooks fail open.** Every new condition in a hook must end with the read
  going through when delegation is impossible. Never brick the agent.
- **Hooks never emit `allow`.** Deny, or stay silent.
- **Never evaluate a command string.** The Bash hook reads commands as data.
- **No new runtime dependencies.** `claude` and `jq` is the whole list, and it
  should stay the whole list.
- **No telemetry, ever.** Nothing leaves the machine except the delegation the
  user asked for, to the account they already use.

## Adding a mode

A mode is one Markdown file in `plugins/understudy/modes/`. Before proposing a
new one, check that it cannot be a local override in
`~/.config/understudy/modes/` instead — most of them can, and a mode that only
helps one codebase does not belong in the repo.

A bundled mode needs: a clear job the two existing modes do not already cover,
explicit output rules, and an explicit instruction for what to do when the
input does not support an answer.

## Reporting a bug

Include the output of `understudy-doctor`, your OS, and `claude --version`.
If a hook misfired, include the file's line count and the command you ran.
