# ops/ — alerts and timers on the box that runs the stack

An alert is a condition: one email when it starts failing, one when it recovers, `[FLAPPING]` when it flaps
(`lib/ops-alert.sh`, and the same machine for Python callers in `lib/ops_alert_machine.py`; both run every scenario
in `testdata/ops-alert-conditions.json`). `ops-alerts.sh` reads and acknowledges the durable queue;
`ops-alerts-settle.sh` is the timer tick that announces recoveries; `ops-alert-unit-failure.sh` is the `OnFailure=`
hook every timer-driven unit names. `install-units.sh` renders `systemd/*.in` for this project and installs them in
user scope. The runbook is `docs/runbooks/alerts.md`.

**Needs.** The process section (`scripts/lib/harness-env.sh`, `scripts/lib/selftest-flag.sh`), systemd user units,
and a way to send mail (`ALERT_TRANSPORT` in `harness.env`). Nothing in `scripts/` depends on this section.

**Optional.** A project with its own monitoring leaves this directory out.
