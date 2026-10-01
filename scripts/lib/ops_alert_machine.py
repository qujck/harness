#!/usr/bin/env python3
"""The ops-alert CONDITION state machine: the client half.
(infra_an_ops_alert_is_a_condition_that_emails_once_when_it_starts_failing_and_once_when_it_recovers)

Owner, 2026-09-28: "one when it fails, and one, however much later, when it's fixed — not every fail".

PO RULING (Carl, 2026-09-28), SETTLED RECOVERY:
  * [FAILING] is sent the moment a key starts failing.
  * [RECOVERED] is sent only once the key has stayed recovered for SETTLE (10 min).
  * A re-fail inside that window cancels the pending recovery silently; the failure email stands.
  * More than 4 transitions in 60 minutes sends ONE [FLAPPING], then nothing until the key has been stable for an HOUR.

The KEY is the condition (`main-red`, `unit-failed:<unit>`), never the instance: a second PR entering
the same condition is the same key and sends nothing.

THE SAME MACHINE EXISTS ON THE SERVER (OpsAlertConditionMachine, the /api/ops/alert backstop) and
both run every scenario in scripts/testdata/ops-alert-conditions.json. Change one and the other's
test goes red; that shared list is the only thing keeping two languages in step.

Pure core: step(state, op, now) -> (state, emails). Everything else here is file I/O around it.
"""
import json
import os
import sys
import tempfile

SETTLE_S = 10 * 60
FLAP_WINDOW_S = 60 * 60
FLAP_MAX = 4


def _blank():
    return {"state": "none", "announced": "none", "failing_since": None, "recovered_since": None,
            "transitions": [], "hold": False, "last_seen": None, "subject": "", "body": "", "recovery_note": ""}


def _hhmm(epoch):
    import time
    return time.strftime("%H:%MZ", time.gmtime(epoch))


def _dur(seconds):
    seconds = max(0, int(seconds))
    h, rem = divmod(seconds, 3600)
    m = rem // 60
    return f"{h}h{m:02d}m" if h else f"{m}m"


def step(state, op, now, key="", subject=None, body=None):
    """One reading (op = failing | recovered) or one scheduled check (op = tick). Pure."""
    s = dict(_blank(), **(state or {}))
    s["transitions"] = list(s.get("transitions") or [])
    emails = []

    # 1. THE SETTLE CHECK RUNS FIRST, ON EVERY CALL, so a tick with no reading can fire it.
    # ⚠ A FLAPPING KEY NEEDS AN HOUR OF STABILITY, NOT THE ORDINARY 10 MINUTES. DECISIONS 2026-09-28
    # (owner-approved) says the flap guard "holds until the key is stable for an hour". This used the
    # 10-minute settle for both, so one quiet 10-minute gap in a flapping key sent [RECOVERED], cleared
    # the hold AND the transition list, and the next failure sent a fresh [FAILING] — a steady
    # FAILING / RECOVERED / FLAPPING stream on any key that flaps with gaps longer than the settle.
    # Measured on unit-failed:strength-pr-refresh.service, 2026-09-29: FLAPPING 07:45, then a
    # RECOVERED+FAILING pair 39 minutes later. (infra_a_condition_written_by_two_senders_from_two_state_dirs_defeats_the_flap_guard;
    # Carl's ruling: the owner's record wins over the PO's "until it settles".)
    quiet_needed = FLAP_WINDOW_S if s["announced"] == "flapping" else SETTLE_S
    if (s["state"] == "recovered" and s["recovered_since"] is not None
            and now - s["recovered_since"] >= quiet_needed and s["announced"] in ("failing", "flapping")):
        was = f", after failing for {_dur(s['recovered_since'] - s['failing_since'])} (since {_hhmm(s['failing_since'])})" \
            if s["failing_since"] is not None else ""
        note = f"{s['recovery_note']}\n\n" if s.get("recovery_note") else ""
        emails.append({"kind": "RECOVERED",
                       "subject": f"[RECOVERED] {key} — {s['subject']}".rstrip(" —"),
                       "body": f"Recovered at {_hhmm(s['recovered_since'])}, held {quiet_needed // 60} min{was}.\n\n{note}What was failing:\n{s['body']}"})
        # ⚠ THE TRANSITION LIST IS NOT RESET HERE. It used to be (`transitions=[]`), so every settled
        # recovery wiped the count the flap guard reads — and a key whose gaps are longer than the
        # settle announces a recovery on EVERY cycle, so its count never passed one or two and the
        # guard could NEVER trip. That was the owner's endless FAILING / RECOVERED stream. The list is
        # already pruned to the flap window on every reading; that pruning is the only reset it needs.
        s.update(announced="recovered", recovered_since=None, hold=False, failing_since=None, recovery_note="")

    if op == "tick":
        return s, emails

    s["last_seen"] = now
    # ⚠ ONLY A FAILING READING SETS THE TEXT. The [RECOVERED] email then carries what the failure said —
    # which PRs, which unit — so the owner learns WHAT recovered, not just that something did. A recovered
    # reading's own text is only "it is fine now", which says nothing. (Row 2's verification: the
    # recovery names the duration AND the PR(s).) The server machine does the same.
    if op == "failing":
        if subject is not None:
            s["subject"] = subject
        if body is not None:
            s["body"] = body
    # A recovered reading's own text is kept apart as the RECOVERY NOTE — what fixed it (the fixing merge,
    # the run that went green) — and the [RECOVERED] email carries both: the note, then what was failing.
    elif op == "recovered" and s["state"] == "failing" and body:
        s["recovery_note"] = body

    if op == "failing":
        if s["state"] == "failing":
            return s, emails                      # already failing: coalesced, no email
        s["transitions"] = [t for t in s["transitions"] if t > now - FLAP_WINDOW_S] + [now]
        s["state"] = "failing"
        s["recovered_since"] = None               # a pending recovery is cancelled SILENTLY
        s["recovery_note"] = ""
        if s["hold"]:
            return s, emails
        if len(s["transitions"]) > FLAP_MAX:
            emails.append(_flapping(s, key, now))
            s.update(hold=True, announced="flapping")
        elif s["announced"] != "failing":
            emails.append({"kind": "FAILING",
                           "subject": f"[FAILING] {key} — {s['subject']}".rstrip(" —"),
                           "body": f"Failing since {_hhmm(now)}. One email now; one more when it has stayed "
                                   f"recovered for {SETTLE_S // 60} min. Repeats of this condition send nothing.\n\n{s['body']}"})
            s.update(announced="failing", failing_since=now)
        return s, emails

    if op == "recovered":
        if s["state"] != "failing":
            return s, emails                      # never failing, or already recovered: nothing
        s["transitions"] = [t for t in s["transitions"] if t > now - FLAP_WINDOW_S] + [now]
        s["state"] = "recovered"
        s["recovered_since"] = now                # announced later, by the settle check
        if not s["hold"] and len(s["transitions"]) > FLAP_MAX:
            emails.append(_flapping(s, key, now))
            s.update(hold=True, announced="flapping")
        return s, emails

    raise ValueError(f"unknown op {op!r} (failing | recovered | tick)")


def _flapping(s, key, now):
    return {"kind": "FLAPPING",
            "subject": f"[FLAPPING] {key} — {s['subject']}".rstrip(" —"),
            "body": f"{len(s['transitions'])} state changes in the last {FLAP_WINDOW_S // 60} min (latest {_hhmm(now)}). "
                    f"No more email for this condition until it has stayed recovered for {FLAP_WINDOW_S // 60} min.\n\n{s['body']}"}


# ── file I/O ──────────────────────────────────────────────────────────────────────────────────
def _load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return None


def _save(path, state):
    # Atomic replace: a watcher killed mid-write must not leave half a state file, which would read
    # as "no state" and re-send a [FAILING] the owner has already had.
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o2775, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    with os.fdopen(fd, "w") as f:
        json.dump(state, f)
    # ⚠ GROUP-READABLE AND -WRITABLE: mkstemp makes 0600, and the store is shared between the user and the
    # ironforge service account. A 0600 file written by one would be unreadable to the other, which would
    # read as "no state" and re-send a [FAILING] the owner already had.
    os.chmod(tmp, 0o664)
    os.replace(tmp, path)


def _path(state_dir, key):
    return os.path.join(state_dir, key.replace("/", "%2F"))


def run_vectors(path):
    """Every scenario in the shared list; returns the failures as strings."""
    doc = json.load(open(path))
    assert doc["settle_minutes"] * 60 == SETTLE_S and doc["flap_window_minutes"] * 60 == FLAP_WINDOW_S \
        and doc["flap_max_transitions"] == FLAP_MAX, "the vectors' constants and this machine's disagree"
    fails = []
    for sc in doc["scenarios"]:
        state, got = None, []
        for stp in sc["steps"]:
            state, emails = step(state, stp["op"], stp["t"] * 60, key="k", subject="s", body="b")
            got += [[stp["t"], e["kind"]] for e in emails]
        if got != sc["expect"]:
            fails.append(f"{sc['name']}: got {got}, want {sc['expect']}")
    if not doc["scenarios"]:
        fails.append("the vectors file holds no scenarios — every pass above would be vacuous")
    return fails, len(doc["scenarios"])


def main(argv):
    if argv and argv[0] == "--self-test":
        # With no path, the repo's own vectors: verify.sh's self-test tier calls `<script> --self-test` bare.
        vectors = argv[1] if len(argv) >= 2 else os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "testdata", "ops-alert-conditions.json")
        fails, n = run_vectors(vectors)
        for f in fails:
            print(f"  FAIL {f}")
        print(f"ops_alert_machine: {n - len(fails)} of {n} scenarios agree with the shared vectors")
        return 1 if fails else 0
    # ⚠ SEND BEFORE COMMIT. `step` and `settle-due` write the new state beside the old one as <key>.next and
    # print the emails; the caller sends them and only then runs `commit` (or `discard` if a send failed).
    # Committing first would mark a failure announced when the send then failed, and every later reading
    # would be coalesced against an email nobody received. The API backstop does the same, in a transaction.
    if len(argv) == 7 and argv[0] == "step":        # step <state_dir> <key> <op> <now> <subject> <body>
        _, state_dir, key, op, now, subject, body = argv
        p = _path(state_dir, key)
        state, emails = step(_load(p), op, int(now), key=key, subject=subject, body=body)
        if emails:
            _save(p + ".next", state)
        else:
            _save(p, state)                         # nothing to send: nothing can fail, commit now
        for e in emails:
            print(json.dumps(dict(e, key=key)))
        return 0
    if len(argv) == 3 and argv[0] == "settle-due":  # settle-due <state_dir> <now>
        _, state_dir, now = argv
        if not os.path.isdir(state_dir):
            return 0
        for name in sorted(os.listdir(state_dir)):
            if name.startswith(".") or name.endswith(".next"):
                continue
            p = os.path.join(state_dir, name)
            key = name.replace("%2F", "/")
            state, emails = step(_load(p), "tick", int(now), key=key)
            if emails:
                _save(p + ".next", state)
            for e in emails:
                print(json.dumps(dict(e, key=key)))
        return 0
    if len(argv) == 3 and argv[0] == "open":        # open <state_dir> <prefix> -> keys whose latest reading is failing
        _, state_dir, prefix = argv
        if os.path.isdir(state_dir):
            for name in sorted(os.listdir(state_dir)):
                if name.startswith(".") or name.endswith(".next"):
                    continue
                key = name.replace("%2F", "/")
                st = _load(os.path.join(state_dir, name)) or {}
                if key.startswith(prefix) and st.get("state") == "failing":
                    print(key)
        return 0
    if len(argv) == 3 and argv[0] in ("commit", "discard"):  # commit|discard <state_dir> <key>
        p = _path(argv[1], argv[2])
        if os.path.exists(p + ".next"):
            if argv[0] == "commit":
                os.replace(p + ".next", p)
            else:
                os.remove(p + ".next")
        return 0
    print("usage: ops_alert_machine.py --self-test [<vectors.json>] | step <dir> <key> <op> <now> <subject> <body> | settle-due <dir> <now> | commit|discard <dir> <key>",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
