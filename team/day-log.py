#!/usr/bin/env python3
"""The harness's Day log, for the page's Day log pane: each development or verification day started, then each PR
merged under it.

The page runs this in the background and draws what it prints (see "the day log" in team/lib/agents_web.py for the
shape). It is given {"days": N} on stdin and prints one JSON object. The starts are dev-day.log's, the development
day's share is agents-day-budget.log's, and the PRs are AGENTS_PR_REPO's merged list on GitHub. A day counts from when
its start was logged, so work done before the start succeeded sits under the day before. The window opens at the last
start at least N days old, so its oldest PRs still sit under their day. When GitHub cannot be read it prints why on
stderr and exits 1, and the page keeps the log it last had."""
import calendar
import json
import os
import re
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
ROOT = os.environ.get("HARNESS_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.environ.get("HARNESS_PROJECT") or os.path.basename(ROOT)
STATE_DIR = os.environ.get("DAY_LOG_STATE_DIR") or os.path.join(HOME, ".local/state", PROJECT)
PRS = 500


def read_text(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""


def iso_epoch(text):
    return calendar.timegm(time.strptime(text, "%Y-%m-%dT%H:%M:%SZ"))


def day_starts():
    """dev-day.log, oldest first, as (epoch, kind, who). A line that does not parse is left out."""
    out = []
    for line in read_text(os.path.join(STATE_DIR, "dev-day.log")).splitlines():
        f = line.split("\t")
        try:
            if len(f) >= 4 and f[1] in ("development", "verification"):
                out.append((iso_epoch(f[0]), f[1], f[3]))
        except ValueError:
            pass
    return sorted(out, key=lambda r: r[0])


def day_quota_at(at):
    """The share of the week open at this epoch, from agents-day-budget.log, or None. dev-day.sh opens the budget just
    before it logs the start, so a minute's grace either way of the clock."""
    quota = None
    for line in read_text(os.path.join(STATE_DIR, "agents-day-budget.log")).splitlines():
        f = line.split()
        if len(f) < 4 or not f[0].isdigit() or int(f[0]) > at + 60:
            continue
        if f[1] == "end":
            quota = None
        elif f[1] in ("start", "raise") and f[3].isdigit():
            quota = int(f[3])
    return quota


def merged_prs(repo, since):
    """The repository's PRs merged since the epoch, as gh lists them; raises ValueError when GitHub cannot be read."""
    try:
        out = subprocess.run(["gh", "pr", "list", "--repo", repo, "--state", "merged", "--limit", str(PRS),
                              "--search", "merged:>=" + time.strftime("%Y-%m-%d", time.gmtime(since)),
                              "--json", "number,title,mergedAt,url"], capture_output=True, text=True, timeout=90).stdout
        rows = json.loads(out)
    except (OSError, subprocess.SubprocessError, ValueError):
        rows = None
    if not isinstance(rows, list):
        raise ValueError("GitHub could not be read just now")
    return rows


def short_title(title):
    """A PR title opens with its ticket's name, `some_long_slug: what it did`: the log shows what it did."""
    return re.sub(r"^[a-z0-9]+(?:_[a-z0-9]+)+:\s+(?=\S)", "", title)


def title_kind(title):
    """What a PR's ticket name says it is: the word before the first underscore, as `fix` in `fix_a_thing: what it did`."""
    m = re.match(r"([a-z0-9]+)(?:_[a-z0-9]+)+:\s+\S", title)
    return m.group(1) if m else ""


def title_name(title):
    """A PR title closes with who made it, `what it did — Name`: the words, and the name."""
    m = re.match(r"(.*\S)\s+—\s+(\S+)$", title, re.S)
    return (m.group(1), m.group(2)) if m else (title, "")


def plural(n, word):
    return f"{n} {word}{'' if n == 1 else 's'}"


def day_log(days, now=None):
    now = time.time() if now is None else now
    starts = day_starts()
    old = [r for r in starts if r[0] <= now - days * 86400]
    shown = starts[len(old) - 1:] if old else starts
    since = shown[0][0] if shown else now
    rows = []
    for at, kind, who in shown:
        quota = day_quota_at(at)
        rows.append({"at": at, "type": "day", "kind": kind, "by": who,
                     "text": f"Started {kind} day" + ("" if quota is None else f", {quota}%")})
    repo = os.environ.get("AGENTS_PR_REPO", "").strip()
    notes, prs = [], []
    if not repo:
        notes.append("PRs are not shown: AGENTS_PR_REPO is not set.")
    elif shown:
        prs = merged_prs(repo, since)
        if len(prs) >= PRS:
            notes.append("Showing the newest PRs only: there are more in this window than the page reads.")
    merged = 0
    for p in prs:
        try:
            at = iso_epoch(p["mergedAt"])
        except (KeyError, TypeError, ValueError):
            continue
        if at >= since:
            title = p.get("title") or ""
            words, by = title_name(short_title(title))
            rows.append({"at": at, "type": "entry", "kind": title_kind(title), "by": by, "text": words,
                         "url": p.get("url") or "", "label": f"#{p.get('number')}"})
            merged += 1
    rows.sort(key=lambda r: (r["at"], r["type"] == "day"), reverse=True)
    started = len(shown)
    return {"rows": rows, "note": " ".join(notes), "summary": f"{plural(started, 'day')} started, {plural(merged, 'PR')} merged",
            "empty": "No development or verification day has been started"}


def main():
    try:
        days = int(json.loads(sys.stdin.read() or "{}").get("days") or 7)
    except (ValueError, AttributeError):
        days = 7
    try:
        print(json.dumps(day_log(days)))
    except ValueError as e:
        print(e, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
