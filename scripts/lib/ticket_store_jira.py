#!/usr/bin/env python3
"""ticket_store_jira.py — the Jira ticket store behind the harness's one verb set.
(feat_harness_jira_is_a_ticket_store_behind_the_same_verbs — NEW CODE, not a port.)

    python3 scripts/lib/ticket_store_jira.py <verb> [args…]      # invoked by scripts/lib/ticket-store-jira.sh

The verbs, their arguments and their verdict strings are those of scripts/ledger-db.sh (the database
store): a script written against `ledger-db.sh raise <file.json>` works unchanged when harness.env says
TICKET_STORE=jira. What differs is only WHERE the row lives.

ASSUMPTIONS (docs/ticket-store-jira.md states them; the owner corrects any): Jira CLOUD, REST API v3,
auth = email + API token from harness.env (JIRA_BASE_URL, JIRA_PROJECT_KEY, JIRA_EMAIL, JIRA_API_TOKEN;
the token is never in git — scripts/check-no-committed-jira-token.sh refuses one), ONE Jira project per
harness project. Out of scope: Jira Server / Data Center, offline writes.

THE MAPPING (asserted by the self-test, documented in docs/ticket-store-jira.md):
  ticket id            ↔ the Jira issue KEY (e.g. HAR-123). The branch-name-is-the-ticket-id rule holds
                         with the key. A raise's JSON may carry "id" as a human slug: it becomes the
                         issue's SUMMARY prefix and a label, and the key is printed back (`ok:HAR-123`).
  epic / children      ↔ a Jira Epic; children carry `parent` = the epic's key.
  lifecycle status     ↔ JIRA_STATUS_MAP in harness.env (DATA, not code), validated against the
                         project's real workflow before any write (a map naming a status the workflow
                         lacks is REFUSED by name).
  priority             ↔ Jira priority (1 → Highest … 5 → Lowest).
  area                 ↔ a Jira label `area:<area>` (JIRA_AREA_FIELD=label) or a component (=component).
  notes / verification / verification_command / depends_on
                       ↔ description SECTIONS (ADF headings), round-tripped verbatim by `show`.
  claim                ↔ assignee = the session identity's Jira account (looked up by the roster email)
                         PLUS the pushed branch, which stays the atomic lock (feature-ticket.sh).
  amend                ↔ the one description section rewritten + a comment naming who and why.
  park / unpark        ↔ transition to the `parked` status + a comment carrying the ask; back again.
  flip-passing         ↔ transition to `passing` + a comment "passing: PR #N"; archive → `archived`.

TRANSPORTS: `live` (urllib against JIRA_BASE_URL, 429/503 retried with backoff; a final failure is
CANNOT TELL (exit 2) for a read and `refused:jira-unavailable` (exit 1) for a write) and `fixture`
(JIRA_TRANSPORT=fixture: an in-process fake of exactly the endpoints the verbs use, persisted as JSON
under $JIRA_FIXTURE_DIR, with a workflow read from fixtures/jira/workflow.json). The self-test runs
every verb against the fixture; `--live --record` runs the lifecycle against a real project and
rewrites fixtures/jira/recorded/*.json from the real responses so the fake cannot drift from the API.
"""
import base64, json, os, re, sys, time, urllib.request, urllib.error, urllib.parse

HARNESS_STATUSES = ["not_started", "selected", "in_progress", "parked", "passing", "archived", "wont_do"]
DEFAULT_STATUS_MAP = "not_started=To Do,selected=Ready,in_progress=In Progress,parked=Blocked,passing=Done pending,archived=Done,wont_do=Won't Do"
SECTIONS = ["notes", "verification", "verification_command", "depends_on", "user_visible_behavior"]
PRIORITY = {1: "Highest", 2: "High", 3: "Medium", 4: "Low", 5: "Lowest"}

class Refused(Exception):
    """A write the store refused: the verdict string is the message (exit 1)."""
class CannotTell(Exception):
    """A read that could not be made: not 'none', not 'no' (exit 2)."""

# ── config ──────────────────────────────────────────────────────────────────────────────────────────
def env(name, default=None, required=False):
    v = os.environ.get(name, default)
    if required and not v:
        raise CannotTell(f"cannot-tell:{name} is not set in harness.env")
    return v

def parse_status_map(text):
    m = {}
    for pair in [p for p in text.split(",") if p.strip()]:
        if "=" not in pair:
            raise Refused(f"refused:status-map-entry-has-no-equals:{pair.strip()}")
        k, v = pair.split("=", 1); k, v = k.strip(), v.strip()
        if k not in HARNESS_STATUSES:
            raise Refused(f"refused:status-map-names-an-unknown-harness-status:{k}")
        m[k] = v
    missing = [s for s in HARNESS_STATUSES if s not in m]
    if missing:
        raise Refused("refused:status-map-is-missing:" + ",".join(missing))
    return m

def validate_status_map(status_map, workflow_statuses):
    """Every Jira status the map names must exist in the project's workflow — refused BY NAME."""
    have = {s.lower() for s in workflow_statuses}
    absent = [v for v in status_map.values() if v.lower() not in have]
    if absent:
        raise Refused("refused:status-map-names-a-status-the-workflow-lacks:" + ",".join(absent))
    return True

# ── ADF: the description as sections ───────────────────────────────────────────────────────────────
def adf_text(t): return {"type": "text", "text": t}
def adf_para(t): return {"type": "paragraph", "content": [adf_text(t)] if t else []}
def adf_heading(t, level=3): return {"type": "heading", "attrs": {"level": level}, "content": [adf_text(t)]}
def adf_code(t): return {"type": "codeBlock", "attrs": {"language": "bash"}, "content": [adf_text(t)] if t else []}
def adf_bullets(items): return {"type": "bulletList", "content": [{"type": "listItem", "content": [adf_para(i)]} for i in items]}

def sections_to_adf(row):
    """The harness fields as ADF: a heading per section, verbatim content under it."""
    content = []
    if row.get("title"):
        content.append(adf_para(row["title"]))
    for s in SECTIONS:
        v = row.get(s)
        if v in (None, "", [], {}):
            continue
        content.append(adf_heading(s))
        if s == "verification_command":
            content.append(adf_code(str(v)))
        elif isinstance(v, list):
            content.append(adf_bullets([str(x) for x in v]))
        else:
            content.append(adf_para(str(v)))
    return {"type": "doc", "version": 1, "content": content}

def _node_text(node):
    if node.get("type") == "text":
        return node.get("text", "")
    return "".join(_node_text(c) for c in node.get("content", []))

def adf_to_sections(doc):
    """Inverse of sections_to_adf: {section: value} with lists back as lists, the command as a string."""
    out, cur = {}, None
    for node in (doc or {}).get("content", []):
        t = node.get("type")
        if t == "heading":
            cur = _node_text(node).strip()
            out[cur] = [] if cur in ("verification", "depends_on") else ""
        elif cur is None:
            out.setdefault("title", _node_text(node))
        elif t == "bulletList":
            out[cur] = [_node_text(li).strip() for li in node.get("content", [])]
        elif t == "codeBlock":
            out[cur] = _node_text(node)
        else:
            out[cur] = (out.get(cur) or "") + _node_text(node) if not isinstance(out.get(cur), list) else out[cur]
    return out

def adf_comment(text): return {"type": "doc", "version": 1, "content": [adf_para(text)]}

# ── transports ──────────────────────────────────────────────────────────────────────────────────────
class LiveTransport:
    """urllib against Jira Cloud REST v3. Retries 429/503 with backoff; a final failure raises."""
    def __init__(self, base, email, token, record_dir=None):
        self.base = base.rstrip("/"); self.record_dir = record_dir
        self.auth = "Basic " + base64.b64encode(f"{email}:{token}".encode()).decode()
        self.n = 0
    def call(self, method, path, body=None, params=None):
        url = self.base + path + (("?" + urllib.parse.urlencode(params)) if params else "")
        data = json.dumps(body).encode() if body is not None else None
        last = None
        for attempt in range(4):
            req = urllib.request.Request(url, data=data, method=method, headers={
                "Authorization": self.auth, "Accept": "application/json", "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    raw = r.read().decode() or "null"
                    out = json.loads(raw)
                    self._record(method, path, params, body, r.status, out)
                    return r.status, out
            except urllib.error.HTTPError as e:
                last = e
                if e.code in (429, 503) and attempt < 3:
                    time.sleep(float(e.headers.get("Retry-After") or (1.5 ** attempt)))
                    continue
                try: out = json.loads(e.read().decode() or "null")
                except Exception: out = None
                self._record(method, path, params, body, e.code, out)
                return e.code, out
            except (urllib.error.URLError, TimeoutError) as e:
                last = e
                if attempt < 3: time.sleep(1.5 ** attempt); continue
        raise CannotTell(f"cannot-tell:jira-unreachable-after-4-tries:{last}")
    def _record(self, method, path, params, body, status, out):
        if not self.record_dir: return
        os.makedirs(self.record_dir, exist_ok=True)
        self.n += 1
        with open(os.path.join(self.record_dir, f"{self.n:03d}-{method}-{re.sub(r'[^A-Za-z0-9]+','_',path).strip('_')}.json"), "w") as f:
            json.dump({"method": method, "path": path, "params": params, "request": body, "status": status, "response": out}, f, indent=2)

class FixtureTransport:
    """An in-process fake of the Jira endpoints the verbs use, persisted as JSON so successive verb
    invocations (separate processes) see one store. The workflow comes from fixtures/jira/workflow.json
    (regenerated from a --live --record run). It is deliberately strict: unknown endpoints raise, so a
    verb that reaches for an endpoint the fake lacks fails LOUDLY in the self-test."""
    def __init__(self, dir_, workflow_file):
        self.dir = dir_; os.makedirs(dir_, exist_ok=True)
        self.state_file = os.path.join(dir_, "state.json")
        self.workflow = json.load(open(workflow_file))
        self.state = json.load(open(self.state_file)) if os.path.exists(self.state_file) else {"issues": {}, "seq": 0, "comments": {}, "users": self.workflow.get("users", [])}
        self.fail_next = os.environ.get("JIRA_FIXTURE_FAIL_NEXT", "")   # "429" | "503" | "down": the retry/cannot-tell arms
    def _save(self):
        json.dump(self.state, open(self.state_file, "w"), indent=1)
    def call(self, method, path, body=None, params=None):
        if self.fail_next:
            code = self.fail_next; os.environ["JIRA_FIXTURE_FAIL_NEXT"] = ""; self.fail_next = ""
            if code == "down": raise CannotTell("cannot-tell:jira-unreachable-after-4-tries:fixture")
            return int(code), {"errorMessages": ["fixture-induced"]}
        key_m = re.match(r"^/rest/api/3/issue/([A-Z][A-Z0-9]+-\d+)(/.*)?$", path)
        if method == "GET" and path == "/rest/api/3/myself":
            return 200, {"accountId": "me-account", "emailAddress": os.environ.get("JIRA_EMAIL", "")}
        if method == "GET" and path == "/rest/api/3/user/search":
            q = (params or {}).get("query", "")
            return 200, [u for u in self.state["users"] if u.get("emailAddress") == q]
        if method == "GET" and re.match(r"^/rest/api/3/project/[A-Z][A-Z0-9]+/statuses$", path):
            return 200, [{"name": "Task", "statuses": [{"name": s} for s in self.workflow["statuses"]]}]
        if method == "POST" and path == "/rest/api/3/issue":
            self.state["seq"] += 1
            key = f"{body['fields']['project']['key']}-{self.state['seq']}"
            fields = dict(body["fields"]); fields["status"] = {"name": self.workflow["initial"]}; fields.setdefault("assignee", None)
            self.state["issues"][key] = {"key": key, "fields": fields}; self._save()
            return 201, {"id": str(1000 + self.state["seq"]), "key": key}
        if key_m:
            key, sub = key_m.group(1), key_m.group(2) or ""
            issue = self.state["issues"].get(key)
            if not issue: return 404, {"errorMessages": ["Issue does not exist or you do not have permission to see it."]}
            if method == "GET" and sub == "":
                return 200, issue
            if method == "PUT" and sub == "":
                issue["fields"].update(body.get("fields", {})); self._save(); return 204, None
            if method == "GET" and sub == "/transitions":
                cur = issue["fields"]["status"]["name"]
                return 200, {"transitions": [{"id": str(i), "name": t["name"], "to": {"name": t["to"]}} for i, t in enumerate(self.workflow["transitions"]) if t["from"] in ("*", cur)]}
            if method == "POST" and sub == "/transitions":
                tid = body["transition"]["id"]; cur = issue["fields"]["status"]["name"]
                allowed = {str(i): t for i, t in enumerate(self.workflow["transitions"]) if t["from"] in ("*", cur)}
                if tid not in allowed: return 400, {"errorMessages": [f"Transition id '{tid}' is not valid for this issue."]}
                issue["fields"]["status"] = {"name": allowed[tid]["to"]}; self._save(); return 204, None
            if method == "PUT" and sub == "/assignee":
                acc = (body or {}).get("accountId")
                issue["fields"]["assignee"] = next((u for u in self.state["users"] if u["accountId"] == acc), None) if acc else None
                self._save(); return 204, None
            if method == "POST" and sub == "/comment":
                self.state["comments"].setdefault(key, []).append({"id": str(len(self.state["comments"].get(key, [])) + 1), "body": body["body"], "author": {"displayName": os.environ.get("JIRA_EMAIL", "")}}); self._save()
                return 201, self.state["comments"][key][-1]
            if method == "GET" and sub == "/comment":
                return 200, {"comments": self.state["comments"].get(key, [])}
        if method == "POST" and path == "/rest/api/3/search/jql":
            jql = body.get("jql", ""); rows = list(self.state["issues"].values())
            m = re.search(r'status\s*=\s*"([^"]+)"', jql)
            if m: rows = [r for r in rows if r["fields"]["status"]["name"] == m.group(1)]
            m = re.search(r'labels\s*=\s*"([^"]+)"', jql)
            if m: rows = [r for r in rows if m.group(1) in r["fields"].get("labels", [])]
            if "assignee is EMPTY" in jql: rows = [r for r in rows if not r["fields"].get("assignee")]
            if "assignee is not EMPTY" in jql: rows = [r for r in rows if r["fields"].get("assignee")]
            return 200, {"issues": rows}
        raise CannotTell(f"cannot-tell:the-fixture-has-no-endpoint-for:{method} {path}")

# ── the store ───────────────────────────────────────────────────────────────────────────────────────
class JiraStore:
    def __init__(self):
        self.project = env("JIRA_PROJECT_KEY", required=True)
        self.status_map = parse_status_map(env("JIRA_STATUS_MAP", DEFAULT_STATUS_MAP))
        self.rev = {v.lower(): k for k, v in self.status_map.items()}
        self.area_mode = env("JIRA_AREA_FIELD", "label")
        if env("JIRA_TRANSPORT", "live") == "fixture":
            root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
            self.t = FixtureTransport(env("JIRA_FIXTURE_DIR", os.path.join(root, ".agent", "jira-fixture")),
                                      env("JIRA_WORKFLOW_FILE", os.path.join(root, "fixtures", "jira", "workflow.json")))
        else:
            self.t = LiveTransport(env("JIRA_BASE_URL", required=True), env("JIRA_EMAIL", required=True),
                                   env("JIRA_API_TOKEN", required=True), env("JIRA_RECORD_DIR"))
        self._validated = False

    # ── helpers ──
    def _call(self, method, path, body=None, params=None):
        """429 and 503 are retried with backoff whatever the transport (the fixture can fail once on purpose)."""
        for attempt in range(4):
            code, out = self.t.call(method, path, body, params)
            if code in (429, 503) and attempt < 3:
                time.sleep(min(float(os.environ.get("JIRA_RETRY_BASE_S", "0.2")) * (2 ** attempt), 30)); continue
            return code, out
        return code, out
    def _write(self, method, path, body=None, params=None):
        try: code, out = self._call(method, path, body, params)
        except CannotTell as e: raise Refused("refused:jira-unavailable:" + str(e))
        if code >= 400: raise Refused(f"refused:jira-{code}:" + ";".join((out or {}).get("errorMessages", []) or [json.dumps((out or {}).get("errors", {}))]))
        return out
    def _read(self, method, path, body=None, params=None):
        code, out = self._call(method, path, body, params)
        if code == 404: return None
        if code >= 400: raise CannotTell(f"cannot-tell:jira-{code}:" + ";".join((out or {}).get("errorMessages", [])))
        return out
    def ensure_workflow(self):
        if self._validated: return
        statuses = self._read("GET", f"/rest/api/3/project/{self.project}/statuses")
        names = sorted({s["name"] for t in (statuses or []) for s in t.get("statuses", [])})
        validate_status_map(self.status_map, names); self._validated = True
    def _issue(self, key):
        if not re.match(r"^[A-Z][A-Z0-9]+-\d+$", key or ""): return None
        return self._read("GET", f"/rest/api/3/issue/{key}")
    def _status_of(self, issue):
        name = issue["fields"]["status"]["name"]
        return self.rev.get(name.lower(), "unmapped:" + name)
    def _transition_to(self, key, harness_status):
        self.ensure_workflow()
        target = self.status_map[harness_status]
        tr = self._read("GET", f"/rest/api/3/issue/{key}/transitions") or {"transitions": []}
        hit = [t for t in tr["transitions"] if t["to"]["name"].lower() == target.lower()]
        if not hit: raise Refused(f"refused:no-transition-from-current-status-to:{target}")
        self._write("POST", f"/rest/api/3/issue/{key}/transitions", {"transition": {"id": hit[0]["id"]}})
    def _comment(self, key, text):
        self._write("POST", f"/rest/api/3/issue/{key}/comment", {"body": adf_comment(text)})
    def _me(self):
        return os.environ.get("HARNESS_AGENT_NAME") or os.environ.get("GIT_AUTHOR_NAME") or "?"
    def _my_account(self):
        email = os.environ.get("GIT_AUTHOR_EMAIL", "")
        users = self._read("GET", "/rest/api/3/user/search", params={"query": email}) or []
        if not users: raise Refused(f"refused:no-jira-account-for-the-session-email:{email}")
        return users[0]["accountId"]
    def _row(self, issue):
        f = issue["fields"]; secs = adf_to_sections(f.get("description"))
        labels = f.get("labels", []) or []
        area = next((l[5:] for l in labels if l.startswith("area:")), None) if self.area_mode == "label" else ((f.get("components") or [{}])[0].get("name"))
        pr_name = (f.get("priority") or {}).get("name")
        prio = next((k for k, v in PRIORITY.items() if v == pr_name), None)
        return {"id": issue["key"], "title": f.get("summary", ""), "status": self._status_of(issue), "area": area, "priority": prio,
                "claimed_by": (f.get("assignee") or {}).get("displayName") or (f.get("assignee") or {}).get("accountId"),
                "parent": (f.get("parent") or {}).get("key"), "slug": next((l for l in labels if not l.startswith("area:")), None),
                **{k: secs.get(k) for k in SECTIONS if k in secs}}

    # ── verbs (the contract; verdict strings as ledger-db.sh prints them) ──
    def raise_(self, path, epic=False):
        row = json.load(open(path))
        self.ensure_workflow()
        if row.get("status", "not_started") != "not_started":
            return f"ready-is-the-pos-move:{self._me()}" if row.get("status") == "selected" else f"refused:a-raise-arrives-not_started-not:{row.get('status')}"
        if "verification" in row and not isinstance(row["verification"], list):
            return "verification-not-a-list:" + type(row["verification"]).__name__
        slug = row.get("id", "")
        if slug:
            found = self._read("POST", "/rest/api/3/search/jql", {"jql": f'project = {self.project} AND labels = "{slug}"', "fields": ["summary"]}) or {"issues": []}
            if found["issues"]: return f"exists:{found['issues'][0]['key']}"
        parent = row.get("parent")
        if parent and not self._issue(parent): return f"unknown-parent:{parent}"
        fields = {"project": {"key": self.project}, "summary": row.get("title") or slug, "issuetype": {"name": "Epic" if epic else "Task"},
                  "description": sections_to_adf(row), "labels": [l for l in [slug] if l]}
        if row.get("priority") in PRIORITY: fields["priority"] = {"name": PRIORITY[int(row["priority"])]}
        if row.get("area"):
            if self.area_mode == "label": fields["labels"].append("area:" + row["area"])
            else: fields["components"] = [{"name": row["area"]}]
        if parent: fields["parent"] = {"key": parent}
        out = self._write("POST", "/rest/api/3/issue", {"fields": fields})
        key = out["key"]
        if self.status_map["not_started"].lower() != (self._issue(key)["fields"]["status"]["name"]).lower():
            self._transition_to(key, "not_started")
        if epic:
            for child in row.get("children", []):
                child = dict(child); child["parent"] = key
                tmp = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"jira-child-{os.getpid()}.json"); json.dump(child, open(tmp, "w"))
                v = self.raise_(tmp); os.unlink(tmp)
                if not v.startswith("ok"): return f"refused:child-{child.get('id')}:{v}"
        return f"ok:{key}"
    def groom(self, key, why):
        issue = self._issue(key)
        if not issue: return f"unknown:{key}"
        if self._status_of(issue) != "not_started": return f"refused:not-not_started:{self._status_of(issue)}"
        self._transition_to(key, "selected"); self._comment(key, f"groomed to selected by {self._me()}: {why}"); return "ok"
    def claim(self, key):
        issue = self._issue(key)
        if not issue: return f"unknown:{key}"
        st = self._status_of(issue); who = (issue["fields"].get("assignee") or {}).get("accountId")
        me = self._my_account()
        if who == me and st == "in_progress": return "already-yours"
        if who and who != me: return f"refused:claimed-by:{(issue['fields']['assignee'] or {}).get('displayName', who)}"
        if st not in ("selected", "in_progress"): return f"refused:not-selected:{st}"
        self._write("PUT", f"/rest/api/3/issue/{key}/assignee", {"accountId": me})
        if st != "in_progress": self._transition_to(key, "in_progress")
        return "ok"
    def park(self, key, why, kind="", summary="", condition=""):
        issue = self._issue(key)
        if not issue: return f"unknown:{key}"
        if self._status_of(issue) != "in_progress": return f"refused:not-in_progress:{self._status_of(issue)}"
        self._transition_to(key, "parked")
        self._comment(key, f"parked by {self._me()}" + (f" [{kind}]" if kind else "") + f": {why}" + (f"\nASK: {summary}" if summary else "") + (f"\nUNPARK WHEN: {condition}" if condition else ""))
        return "ok"
    def unpark(self, key, why):
        issue = self._issue(key)
        if not issue: return f"unknown:{key}"
        if self._status_of(issue) != "parked": return "not-parked"
        self._transition_to(key, "in_progress"); self._comment(key, f"unparked by {self._me()}: {why}"); return "ok"
    def amend(self, key, field, value, why):
        if field not in SECTIONS + ["title"]: return f"refused:not-an-amendable-field:{field}"
        if not why.strip(): return "refused:amend-needs-a-why"
        issue = self._issue(key)
        if not issue: return f"unknown:{key}"
        secs = adf_to_sections(issue["fields"].get("description")); secs["title"] = issue["fields"].get("summary", "")
        before = secs.get(field)
        if field in ("verification", "depends_on"):
            try: value = json.loads(value) if value.strip().startswith("[") else [v for v in value.split("\n") if v]
            except json.JSONDecodeError: return "verification-not-a-list:string"
        secs[field] = value
        fields = {"description": sections_to_adf(secs)}
        if field == "title": fields["summary"] = value
        self._write("PUT", f"/rest/api/3/issue/{key}", {"fields": fields})
        self._comment(key, f"amend {field} by {self._me()}: {why}\nBEFORE: {json.dumps(before)}\nAFTER: {json.dumps(value)}")
        return "ok"
    def flip_passing(self, key, pr):
        issue = self._issue(key)
        if not issue: return f"unknown:{key}"
        if not str(pr).isdigit(): return "refused:flip-passing-needs-a-pr-number"
        if self._status_of(issue) not in ("in_progress", "parked"): return f"refused:not-in_progress:{self._status_of(issue)}"
        self._transition_to(key, "passing"); self._comment(key, f"passing: PR #{pr} merged — flipped by {self._me()}"); return "ok"
    def set_status(self, key, status, why):
        issue = self._issue(key)
        if not issue: return f"unknown:{key}"
        cur = self._status_of(issue)
        if status == "archived" and cur != "passing": return f"refused:archive-needs-passing:{cur}"
        if status == "wont_do" and cur in ("archived", "passing"): return f"refused:finished:{cur}"
        self._transition_to(key, status); self._comment(key, f"{status} by {self._me()}: {why}"); return "ok"
    def release(self, key, why):
        issue = self._issue(key)
        if not issue: return f"unknown:{key}"
        st = self._status_of(issue)
        if st in ("archived", "wont_do"): return f"release:archived:{st}" if st == "archived" else "ok"
        if not issue["fields"].get("assignee"): return "already-unassigned"
        return f"refused:not-finished:{st}"
    def stand_down(self, key, why):
        issue = self._issue(key)
        if not issue: return f"unknown:{key}"
        if not issue["fields"].get("assignee"): return "already-unassigned"
        self._write("PUT", f"/rest/api/3/issue/{key}/assignee", {"accountId": None})
        if self._status_of(issue) == "in_progress": self._transition_to(key, "selected")
        self._comment(key, f"stood down by {self._me()}: {why}"); return "ok"
    def intent(self, key, intent, note):
        if intent not in ("building", "holding", "travelling"): return f"refused:not-an-intent:{intent}"
        if not self._issue(key): return f"unknown:{key}"
        self._comment(key, f"intent {intent} ({self._me()})" + (f": {note}" if note else "")); return "ok"
    def record_issue(self, key, n):
        return "ok" if self._issue(key) else f"unknown:{key}"   # the key IS the issue: nothing to record
    def ticket_row(self, key):
        i = self._issue(key); return "" if not i else self._status_of(i)
    def ticket_owner(self, key):
        i = self._issue(key); return "" if not i else ((i["fields"].get("assignee") or {}).get("displayName") or "")
    def show(self, key):
        i = self._issue(key); return "" if not i else json.dumps(self._row(i), indent=2, ensure_ascii=False)
    def frontier(self):
        rows = self._read("POST", "/rest/api/3/search/jql", {"jql": f'project = {self.project} AND status = "{self.status_map["selected"]}" AND assignee is EMPTY', "fields": ["summary", "labels", "priority", "status"]}) or {"issues": []}
        out = [self._row(r) for r in rows["issues"]]
        return "\n".join(f"{r['id']}|{r['area'] or ''}|{r['priority'] or ''}" for r in sorted(out, key=lambda r: (r["priority"] or 9, r["id"])))
    def board(self):
        rows = self._read("POST", "/rest/api/3/search/jql", {"jql": f'project = {self.project} AND status = "{self.status_map["in_progress"]}"', "fields": ["summary", "labels", "assignee", "status"]}) or {"issues": []}
        return "\n".join(f"{r['id']}|{r['area'] or ''}|{r['claimed_by'] or '-'}" for r in map(self._row, rows["issues"]))
    def comments(self, key):
        c = self._read("GET", f"/rest/api/3/issue/{key}/comment") or {"comments": []}
        return "\n".join(f"{x.get('id')}|{x.get('author', {}).get('displayName', '')}|{_node_text(x.get('body', {})).replace(chr(10), ' / ')}" for x in c["comments"])
    def answer(self, key, text):
        if not self._issue(key): return f"unknown:{key}"
        self._comment(key, f"{self._me()}: {text}"); return "ok"
    def ping(self):
        return "ok" if self._read("GET", "/rest/api/3/myself") is not None else "cannot-tell"
    def dump_workflow(self):
        """fixtures/jira/workflow.json regenerated from the REAL project: its statuses, and the users the
        roster's emails resolve to. Transitions cannot be listed project-wide through v3 without admin
        scope, so the recorded lifecycle's transitions are kept from the previous file when present."""
        statuses = self._read("GET", f"/rest/api/3/project/{self.project}/statuses") or []
        names = sorted({s["name"] for t in statuses for s in t.get("statuses", [])})
        root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        prev_f = os.path.join(root, "fixtures", "jira", "workflow.json")
        prev = json.load(open(prev_f)) if os.path.exists(prev_f) else {}
        users = []
        try:
            roster = json.load(open(os.path.join(root, "agents", "roster.json")))
            for a in roster.get("agents", []) + roster.get("machines", []):
                hit = self._read("GET", "/rest/api/3/user/search", params={"query": a.get("email", "")}) or []
                users += [{"accountId": u["accountId"], "emailAddress": a.get("email"), "displayName": u.get("displayName", a.get("name"))} for u in hit[:1]]
        except (OSError, json.JSONDecodeError):
            pass
        return json.dumps({"_note": prev.get("_note", "regenerated from the real project by --live --record"),
                           "initial": self.status_map["not_started"], "statuses": names,
                           "transitions": prev.get("transitions", []), "users": users or prev.get("users", [])}, indent=2)

READ_VERBS = {"ticket-row", "ticket-owner", "show", "frontier", "board", "comments", "ping", "whoami", "dump-workflow", "validate-status-map"}
UNSUPPORTED = {"session-entry": "session entries are ledger rows (child 4); Jira has no equivalent — keep a ledger for them or use TICKET_STORE=db",
               "session-entries": "see session-entry", "sync-agent-roles": "Jira accounts are managed in Jira, not by this harness",
               "clear-refusal": "no refusal store in the Jira adapter", "po-owner": "roles come from agents/roster.json, not Jira",
               "po-queue": "use `frontier`", "waiting": "use a JQL board for parked issues", "summary": "use Jira's own dashboards",
               "orphans": "assignees in Jira are accounts, never departed agents; use Jira's user admin", "ticket-grep": "use `show` per key or JQL"}

def main(argv):
    if not argv: print("usage: ticket_store_jira.py <verb> [args…]", file=sys.stderr); return 64
    verb, args = argv[0], argv[1:]
    if verb in UNSUPPORTED:
        print(f"ticket-store: '{verb}' is not supported by the 'jira' store — {UNSUPPORTED[verb]} (not a silent pass)", file=sys.stderr); return 2
    try:
        if verb == "whoami": print(os.environ.get("HARNESS_AGENT_NAME") or os.environ.get("GIT_AUTHOR_NAME") or ""); return 0
        s = JiraStore()
        if verb in ("raise", "raise-epic"):
            if not args: print(f"usage: ledger-db.sh {verb} <file.json>", file=sys.stderr); return 64
            if not os.path.exists(args[0]): print(f"ledger-db: cannot read {args[0]}", file=sys.stderr); return 66
            try: json.load(open(args[0]))
            except json.JSONDecodeError: print(f"ledger-db: {args[0]} is not valid JSON — nothing was sent", file=sys.stderr); return 65
            v = s.raise_(args[0], epic=(verb == "raise-epic"))
        elif verb == "groom": v = s.groom(args[0], " ".join(args[1:])) if len(args) >= 2 else "usage"
        elif verb == "claim": v = s.claim(args[0])
        elif verb == "park":
            opts = {}; rest = list(args)
            while rest and rest[0].startswith("--"):
                opts[rest[0][2:]] = rest[1]; rest = rest[2:]
            v = s.park(rest[0], " ".join(rest[1:]), opts.get("kind", ""), opts.get("summary", ""), opts.get("condition", ""))
        elif verb == "unpark": v = s.unpark(args[0], " ".join(args[1:]))
        elif verb == "amend": v = s.amend(args[0], args[1], args[2], " ".join(args[3:])) if len(args) >= 4 else "usage"
        elif verb == "flip-passing": v = s.flip_passing(args[0], args[1] if len(args) > 1 else "")
        elif verb == "archive": v = s.set_status(args[0], "archived", " ".join(args[1:]))
        elif verb == "wont-do": v = s.set_status(args[0], "wont_do", " ".join(args[1:])) if len(args) >= 2 else "usage"
        elif verb == "release": v = s.release(args[0], " ".join(args[1:]))
        elif verb == "stand-down": v = s.stand_down(args[0], " ".join(args[1:]))
        elif verb == "intent": v = s.intent(args[0], args[1] if len(args) > 1 else "", args[2] if len(args) > 2 else "")
        elif verb == "record-issue": v = s.record_issue(args[0], args[1] if len(args) > 1 else "")
        elif verb == "ticket-row": v = s.ticket_row(args[0])
        elif verb == "ticket-owner": v = s.ticket_owner(args[0])
        elif verb == "show": v = s.show(args[0])
        elif verb == "frontier": v = s.frontier()
        elif verb == "board": v = s.board()
        elif verb == "comments": v = s.comments(args[0])
        elif verb == "answer": v = s.answer(args[0], " ".join(args[1:]))
        elif verb == "ping": v = s.ping()
        elif verb == "validate-status-map": s.ensure_workflow(); v = "ok"
        elif verb == "dump-workflow": v = s.dump_workflow()
        else:
            print(f"ticket-store: '{verb}' is not a verb of the contract", file=sys.stderr); return 64
        if v == "usage": print(f"usage: ledger-db.sh {verb} <id> …", file=sys.stderr); return 2
        if v: print(v)
        if verb in READ_VERBS: return 0
        ok = v.startswith("ok") or v in ("already-yours", "not-parked", "already-unassigned") or v.startswith("release:archived:")
        return 0 if ok else 1
    except IndexError:
        print(f"usage: ledger-db.sh {verb} <id> …", file=sys.stderr); return 2
    except Refused as e:
        print(str(e)); return 1
    except CannotTell as e:
        if verb in READ_VERBS:
            print(str(e), file=sys.stderr); return 2
        # a WRITE that could not even read its subject is refused, not "cannot tell": nothing was written
        print("refused:jira-unavailable:" + str(e)); return 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
