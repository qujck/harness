# Runbook: alerts are conditions

*(feat_harness_ops_alerts_are_conditions_with_one_email_on_failing_and_one_on_recovery)*

**The contract.** An alert is a **condition** with a **key** (`unit-failed:<unit>`, `main-red`,
`box-memory-pressure` — the condition, never the instance). A sender reports a reading:
`ops_alert_condition <key> failing|recovered <subject> <body>` (`scripts/lib/ops-alert.sh`). The
state machine (`scripts/lib/ops_alert_machine.py`) turns readings into at most these emails:

| when | email |
|---|---|
| the first `failing` reading | `[FAILING] <key> — <subject>` — once; 100 more failing readings send nothing |
| a `recovered` reading that has **held the settle window** (10 min) | `[RECOVERED] <key>` — once; a re-fail inside the window cancels it silently |
| the 5th transition inside an hour | `[FLAPPING] <key>` — once, then silence while it flaps; `[RECOVERED]` only once the last recovery has held the flap window (60 min) |

A send that fails does **not** advance the state: the next reading sends what was never delivered.
The shared vectors (`scripts/testdata/ops-alert-conditions.json`, 12 scenarios) are run by both the
machine's and the library's self-tests, so neither can drift.

**One state location, resolved by the library.** `ops_alert_state_dir` is `OPS_ALERT_STATE_DIR`,
else `ALERT_STATE_DIR` (harness.env), else `$PLATFORM_VAR/ops-alert-conditions`, else
`~/.local/state/<project>/alerts` — in that order, with no second fallback: a location that cannot be
created is a refusal (exit 2, loud). *Why:* the seeded project had a system-scope unit and a user-scope
one writing one key from two directories; each saw a fresh condition, the flap guard never tripped,
and the owner got a steady stream of mail. Every sender on a box must share the one directory.

**Transport is config** (`harness.env`): `ALERT_TRANSPORT=none` (queue only), `resend` (email:
`ALERT_TO`, `ALERT_FROM`, and `RESEND_ALERT_KEY` in the monitoring dir's `.env` — a secret, never in
the repo), or `post` (`ALERT_POST_URL`, JSON `{subject, body, host}`). `OPS_ALERT_DRY_RUN=1` prints
instead of sending — for a self-test or a by-hand drive, never set on a unit.

**The queue.** Every alert is also written to `<state dir>/ops-alerts.jsonl`; `bash
scripts/ops-alerts.sh` lists what nobody has acted on, `--ack <seq>` marks them; `init.sh` prints
the queue at session start.

**Units.** `scripts/systemd/*.in` are templates (`@@PROJECT@@`, `@@REPO_ROOT@@`);
`bash scripts/install-units.sh` renders them as `<project>-<name>` and installs them in user scope:
- `<project>-unit-failure@.service` — the OnFailure hook: any unit that names
  `OnFailure=<project>-unit-failure@%n.service` reports `unit-failed:<unit>` failing, with the
  journal tail and the unit's current state in the body.
- `<project>-alerts-settle.timer` (every 5 min) → `ops-alerts-settle.sh`: announces recoveries that
  have settled, and sweeps `unit-failed:<unit>` keys whose unit is active again (a recovery reading
  nobody else would make). An unreadable unit state never clears a condition.
Give every timer-driven service the `OnFailure=` line; `install-units.sh --self-test` refuses a
service template without it.

**Driving it once on a box** (what the row asks; record the result in DECISIONS.md): in a scratch
copy with `ALERT_TRANSPORT=none` and a scratch `ALERT_STATE_DIR`, install the units under a scratch
`HARNESS_PROJECT`, add a probe service that fails (`ExecStart=/bin/false`) with the hook, start it →
the journal shows `[FAILING] unit-failed:<probe>`; change it to succeed, start it, and after the
settle tick (≥ 10 min later) the journal shows `[RECOVERED]`. Then disable and remove the scratch units.
