#!/usr/bin/env bash
# Tests the review queue: requests in the fixed form, the reviewer's take and close, who each verdict wakes, the
# delivery lead's order and hold, and agents_web serving the file to its Work pane. Every input is written here;
# nothing live is read: the roster is written here and the ledger is a stand-in.
#
#   bash team/review-queue.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cat > "$T/roster.json" <<'JSON'
{"agents": [
 {"name": "Lead", "role": "delivery-lead", "status": "active"},
 {"name": "Dev", "role": "developer", "status": "active"},
 {"name": "Tess", "role": "tester", "status": "active"},
 {"name": "Tam", "role": "tester", "status": "active"},
 {"name": "Rev", "role": "code-reviewer", "status": "active"},
 {"name": "Tre", "role": "test-reviewer", "status": "active"},
 {"name": "Gone", "role": "tester", "status": "retired"}]}
JSON
# the ledger stand-in: `agent-tickets` prints the rows in $T/held, holder|id|status|park_kind
printf '#!/usr/bin/env bash\n[ "$1" = agent-tickets ] && cat "%s/held"\n' "$T" > "$T/ledger-db.sh"
: > "$T/held"
HOME="$T" python3 - "$HERE" "$T" <<'EOF'
import json, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
here, T = sys.argv[1], sys.argv[2]
Q = os.path.join(T, "q", "review-queue.json")
ENV = {"HOME": T, "AGENT_REVIEW_QUEUE": Q, "ROSTER_FILE": os.path.join(T, "roster.json"), "LEDGER_DB": os.path.join(T, "ledger-db.sh")}

fails = 0
def expect(what, got, want):
    global fails
    if got == want:
        print("ok  ", what)
    else:
        print("FAIL", what, f"\n     got {got!r}, want {want!r}")
        fails += 1

def rq(*args, who="Dev"):
    return subprocess.run([os.path.join(here, "review-queue.py"), *args], capture_output=True, text=True,
                          env={**os.environ, **ENV, "AGENT_NAME": who})

def q():
    return json.load(open(Q))

def notices(to):
    return [n["text"] for n in q()["notices"] if n["to"] == to]

def add(kind, key, head, who="Dev", **more):
    args = ["add", kind, key, "--pr", f"https://x/pr/{key}", "--head", head, "--changed", "the thing", "--read-for", "the risk"]
    for k, v in more.items():
        args += [f"--{k.replace('_', '-')}", v]
    return rq(*args, who=who)

r = add("code", "AB-1", "abc1234", owner="keep it small")
expect("a developer adds a request for the code reviewer", (r.returncode, r.stdout.strip()), (0, "#1 added for the code reviewer, 0 ahead of it"))
expect("the code reviewer is woken with it", len(notices("Rev")), 1)
expect("and the notice says it is the queue's, not the owner's, and how to take it",
       notices("Rev")[0].startswith("[review-queue, not the owner] A request is waiting for you (0 ahead of it): AB-1 from Dev.")
       and "team/review-queue.py take code" in notices("Rev")[0], True)
expect("the lead is not woken by a request", notices("Lead"), [])
expect("the same pull request at the same head is refused", add("code", "AB-1", "abc1234").returncode, 1)
expect("a field over its limit is refused, naming the limit",
       ("keep it to 400" in add("code", "AB-2", "abc9999", changed="x" * 401).stderr), True)
expect("a request missing the form's fields is refused",
       "needs --head" in rq("add", "code", "AB-2", "--pr", "u", "--changed", "c", "--read-for", "r").stderr, True)
expect("a head that is not a sha is refused", add("code", "AB-2", "main").returncode, 1)
expect("a reviewer cannot add", add("code", "AB-2", "abc5678", who="Rev").returncode, 1)
expect("a retired agent cannot add", add("code", "AB-2", "abc5678", who="Gone").returncode, 1)
expect("a test request needs the plan and tests", "needs --files" in add("test", "AB-3", "def5678", who="Tess").stderr, True)
expect("a tester can add, for the test reviewer, with no pull request",
       rq("add", "test", "AB-3", "--head", "def5678", "--files", "plan.md, a.spec.ts", "--changed", "c", "--read-for", "r", who="Tess").returncode, 0)
add("code", "AB-2", "abc5678")
add("code", "AB-4", "abc4444")

expect("only the delivery lead reorders", rq("up", "3", who="Dev").returncode, 1)
rq("up", "4", who="Lead")
expect("up moves a request one place among its kind's waiting", [i["id"] for i in q()["items"] if i["kind"] == "code"], [1, 4, 3])
rq("hold", "1", who="Lead")
expect("only the code reviewer takes code requests", rq("take", "code", who="Tre").returncode, 1)
r = rq("take", "code", who="Rev")
expect("take skips a held request and prints the next in full",
       r.stdout.splitlines()[:3], ["#4 AB-4 for the code reviewer, from Dev: https://x/pr/AB-4 at abc4444", "  Changed: the thing", "  Read for: the risk"])
expect("take again gives the one in hand", rq("take", "code", who="Rev").stdout.splitlines()[0].startswith("#4 "), True)

# A clean code review with a tester holding the ticket in the ledger: the tester is told, the lead is not.
open(os.path.join(T, "held"), "w").write("Dev|AB-4|in_progress|\nTam|AB-4|in_progress|\nTess|AB-9|in_progress|\n")
r = rq("close", "4", "--clean", "approved, no findings", who="Rev")
expect("a clean close tells the tester holding the ticket", r.stdout.strip(), "#4 closed clean; Tam, as tester, is told it is their turn")
expect("in a notice to the tester", len(notices("Tam")), 1)
expect("and wakes no lead", notices("Lead"), [])
expect("a closed request cannot be closed again", rq("close", "4", "--clean", "x", who="Rev").returncode, 1)

# A clean code review with the ledger unreadable: the lead is told it needs a tester.
open(os.path.join(T, "ledger-db.sh"), "w").write("#!/usr/bin/env bash\nexit 3\n")
rq("release", "1", who="Lead")
rq("take", "code", who="Rev")
r = rq("close", "1", "--clean", "approved", who="Rev")
expect("with no tester known to hold the ticket, the lead is told it needs one", (r.returncode, len(notices("Lead"))), (0, 1))

# Findings go to the lead, who passes them on.
rq("take", "code", who="Rev")
r = rq("close", "3", "--findings", "two findings on the PR", who="Rev")
expect("findings wake the lead with the words", "two findings on the PR" in notices("Lead")[-1], True)
expect("and wait on the lead", [i["state"] for i in q()["items"] if i["id"] == 3], ["lead"])
expect("only the lead marks them passed on", rq("passed", "3", who="Rev").returncode, 1)
rq("passed", "3", who="Lead")
expect("passed closes them", [i["state"] for i in q()["items"] if i["id"] == 3], ["done"])

# A clean test review goes back to whoever asked.
rq("take", "test", who="Tre")
expect("the test reviewer's take shows the files", "  Files: plan.md, a.spec.ts" in rq("take", "test", who="Tre").stdout.splitlines(), True)
r = rq("close", "2", "--clean", "cleared, no changes", who="Tre")
expect("a clean test review tells the tester who asked", (r.stdout.strip(), len(notices("Tess"))), ("#2 closed clean; Tess is told", 1))

expect("nothing waiting says so", rq("take", "test", who="Tre").stdout.strip(), "nothing waiting")
add("code", "AB-5", "abc5555")
expect("someone else cannot drop a request", rq("drop", "5", who="Tess").returncode, 1)
expect("the requester can drop their own", rq("drop", "5", who="Dev").returncode, 0)
expect("an unnamed session is refused", subprocess.run([os.path.join(here, "review-queue.py"), "take", "code"], capture_output=True,
       env={k: v for k, v in os.environ.items() if k not in ("AGENT_NAME", "CLAUDE_CODE_SESSION_ID")} | ENV).returncode, 1)

# Twelve requests added at once all land.
with ThreadPoolExecutor(12) as ex:
    list(ex.map(lambda n: add("code", f"CD-{n}", f"{n:07x}"), range(12)))
expect("requests added at once all land, each with its own id",
       len({i["id"] for i in q()["items"] if i["key"].startswith("CD-")}), 12)

# agents_web serves the file to the Work pane.
import importlib.machinery, importlib.util
os.environ.update(HOME=T, AGENT_REVIEW_QUEUE=Q)
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("aw", os.path.join(here, "lib", "agents_web.py"))
spec = importlib.util.spec_from_loader("aw", loader)
aw = importlib.util.module_from_spec(spec)
loader.exec_module(aw)
got = aw.review_queue()
expect("agents_web serves the queue", len(got.get("items", [])), len(q()["items"]))

sys.exit(1 if fails else 0)
EOF
