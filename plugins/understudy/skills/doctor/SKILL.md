---
name: doctor
description: "Check that Understudy delegation is working — CLI, jq, scripts, modes, configuration, and optionally a live round trip. Use when a delegation fails, when a read hook fires unexpectedly, or when the user asks whether Understudy is set up correctly."
---

# Check the Understudy setup

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/understudy-doctor
```

Read-only: it changes nothing and spends nothing.

Add `--probe` to also run one real delegation, which proves authentication and
model access end to end and costs about a tenth of a cent:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/understudy-doctor --probe
```

Report the failing checks and the remediation the doctor printed. Do not try to
fix authentication yourself — `claude auth login` is the user's to run.
