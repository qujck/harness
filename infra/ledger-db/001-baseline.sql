-- 001-baseline.sql — the ledger schema as one baseline: a schema-only pg_dump of the project this
-- template was seeded from, taken 2026-10-01 after its 147th migration, with no owner statements
-- (the container's POSTGRES_USER owns everything) and with the grants kept. Later changes are
-- numbered migrations beside this file, applied by scripts/ledger-migrate.sh and recorded in
-- ledger.schema_migration (the initdb hook records this baseline as "001").
--
-- PostgreSQL database dump
--


-- Dumped from database version 16.14
-- Dumped by pg_dump version 16.14

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: ledger; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA ledger;


--
-- Name: depth; Type: TYPE; Schema: ledger; Owner: -
--

CREATE TYPE ledger.depth AS ENUM (
    'primary',
    'secondary',
    'can_cover'
);


--
-- Name: evidence; Type: TYPE; Schema: ledger; Owner: -
--

CREATE TYPE ledger.evidence AS ENUM (
    'declared',
    'inferred'
);


--
-- Name: park_kind; Type: TYPE; Schema: ledger; Owner: -
--

CREATE TYPE ledger.park_kind AS ENUM (
    'blocked_on_owner',
    'blocked_on_other',
    'banked'
);


--
-- Name: ticket_status; Type: TYPE; Schema: ledger; Owner: -
--

CREATE TYPE ledger.ticket_status AS ENUM (
    'not_started',
    'selected',
    'in_progress',
    'passing',
    'archived',
    'wont_do',
    'blocked',
    'draft',
    'reviewed',
    'parked'
);


--
-- Name: _mark_refused(text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger._mark_refused(p_id text, p_reason text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
  UPDATE ledger.ticket SET mirror_refused_at = now(), mirror_refused_reason = p_reason WHERE id = p_id;
$$;


--
-- Name: add_comment(text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.add_comment(p_ticket text, p_body text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE v_actor text := session_user::text; v_kind text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ledger.ticket WHERE id = p_ticket) THEN RETURN 'no-such-ticket'; END IF;
  IF nullif(btrim(coalesce(p_body,'')),'') IS NULL THEN RETURN 'empty'; END IF;
  -- ⚠ DECIDED HERE, NOT ACCEPTED FROM THE CALLER. A caller-supplied author_kind is a caller-supplied
  -- "this is the owner speaking", which is the one claim on this table that must not be forgeable.
  v_kind := CASE WHEN EXISTS (SELECT 1 FROM ledger.agent WHERE name = v_actor)
                 THEN 'agent' ELSE 'owner' END;
  INSERT INTO ledger.comment(ticket_id, body, author, author_kind) VALUES (p_ticket, p_body, v_actor, v_kind);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN 'refused:' || SQLSTATE || ':' || left(SQLERRM, 120);
END $$;


--
-- Name: adjudicate_retired_park(text, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.adjudicate_retired_park(p_id text, p_outcome text, p_reason text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE
  t ledger.ticket%ROWTYPE;
  me text := session_user;
  holder text;
  holder_offboarded date;
  holder_known boolean;
BEGIN
  IF nullif(btrim(coalesce(p_reason,'')),'') IS NULL THEN RETURN 'need-reason'; END IF;
  IF p_outcome NOT IN ('reassigned','returned','abandoned','delivered') THEN
    RETURN 'bad-outcome:reassigned|returned|abandoned|delivered';
  END IF;

  SELECT * INTO t FROM ledger.ticket WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'no-such-ticket'; END IF;

  -- ⚠ THE READ-ONLY REFUSALS COME FIRST, before any authority check — migration 102's rule, applied
  -- consistently: nobody needs authority to be told an answer that writes nothing.
  holder := coalesce(t.claimed_by, t.parked_by);
  IF holder IS NULL THEN RETURN 'nobody-holds-it'; END IF;

  SELECT offboarded, true INTO holder_offboarded, holder_known
    FROM ledger.agent WHERE name = holder;

  -- Absent from the roster is NOT retired. Refused by name so the caller knows which case it is.
  IF holder_known IS NOT TRUE THEN RETURN 'holder-not-in-roster:'||holder; END IF;
  IF holder_offboarded IS NULL     THEN RETURN 'holder-is-active:'||holder; END IF;

  -- ⚠ HERE, AND NOT EARLIER. Everything above returns without writing.
  IF NOT EXISTS (SELECT 1 FROM ledger.agent WHERE name = me AND offboarded IS NULL)
    THEN RETURN 'not-an-active-agent:'||me; END IF;

  UPDATE ledger.ticket
     SET adjudicated_by   = me,
         adjudicated_at   = now(),
         adjudicated_from = holder,
         updated_at       = now(),
         -- ⚠ 'reassigned' KEEPS status AND every park column. Only answerability moves.
         claimed_by = CASE WHEN p_outcome = 'delivered' THEN t.claimed_by ELSE NULL END,
         claimed_at = CASE WHEN p_outcome = 'delivered' THEN t.claimed_at ELSE NULL END,
         status = CASE p_outcome
                    WHEN 'returned'  THEN 'selected'::ledger.ticket_status
                    WHEN 'abandoned' THEN 'wont_do'::ledger.ticket_status
                    ELSE t.status
                  END,
         -- returned/abandoned leave the park behind; migration 58's CHECK requires the park columns
         -- to be clear on a non-parked row, so they are cleared in exactly those two cases.
         parked_reason = CASE WHEN p_outcome IN ('returned','abandoned') THEN NULL ELSE t.parked_reason END,
         parked_at     = CASE WHEN p_outcome IN ('returned','abandoned') THEN NULL ELSE t.parked_at END,
         parked_by     = CASE WHEN p_outcome IN ('returned','abandoned') THEN NULL ELSE t.parked_by END,
         park_kind     = CASE WHEN p_outcome IN ('returned','abandoned') THEN NULL ELSE t.park_kind END
   WHERE id = p_id;

  INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
  VALUES (p_id, 'adjudicate', me,
          jsonb_build_object('outcome', p_outcome, 'from', holder, 'reason', p_reason));

  RETURN 'ok:'||p_outcome;
END $$;


--
-- Name: amend_requirement(text, text, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.amend_requirement(p_id text, p_field text, p_value text, p_reason text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $_$
DECLARE
  t ledger.ticket%ROWTYPE;
  me text := session_user;
  v_old text;
  v_arr text[];
  v_num smallint;
BEGIN
  -- ⚠ the reason gate comes FIRST, before any lookup, so a reasonless call cannot have a side
  -- effect of any kind — not even a row lock. Same shape as set_status.
  IF nullif(btrim(coalesce(p_reason,'')),'') IS NULL THEN RETURN 'need-reason'; END IF;

  -- ⚠ `status` IS NAMED BEFORE THE WHITELIST IS CONSULTED, so the refusal explains itself. Falling
  -- through to `no-such-field:status` would be true and useless: it reads as a typo, and the next
  -- person's fix is to add it to the list.
  IF p_field = 'status' THEN RETURN 'status-has-its-own-verbs'; END IF;

  IF NOT (p_field = ANY (ledger.amendable_fields())) THEN
    RETURN 'no-such-field:'||coalesce(p_field,'(null)');
  END IF;

  -- ⚠ A NULL VALUE IS REFUSED RATHER THAN WRITTEN. Six of the seven columns are NOT NULL, so a null
  -- would leak a constraint error for six fields and silently blank the seventh — two behaviours
  -- from one input is worse than either.
  IF p_value IS NULL THEN RETURN 'need-value'; END IF;

  SELECT * INTO t FROM ledger.ticket WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'no-such-ticket'; END IF;

  -- ⚠ THE CALLER MUST BE ON THE ROSTER. Not an authorisation tier — an attribution one: the trace
  -- below is the whole control, and a trace naming a role that is not an agent records nothing.
  IF NOT EXISTS (SELECT 1 FROM ledger.v_agent WHERE name = me) THEN
    RETURN 'not-a-rostered-agent:'||me;
  END IF;

  -- The previous value, captured BEFORE the write, because it is half of what makes this a trace.
  EXECUTE format('SELECT ($1).%I::text', p_field) INTO v_old USING t;

  -- ── the typed fields, each refused in this verb's own vocabulary rather than leaking a cast error ──
  IF p_field = 'verification' THEN
    -- text[]. Accepts a JSON array so a multi-item list survives one shell argument intact.
    BEGIN
      SELECT array_agg(value) INTO v_arr
        FROM jsonb_array_elements_text(p_value::jsonb) AS value;
    EXCEPTION WHEN others THEN
      RETURN 'verification-must-be-a-json-array';
    END;
    IF v_arr IS NULL OR array_length(v_arr,1) IS NULL THEN RETURN 'verification-must-not-be-empty'; END IF;
    UPDATE ledger.ticket SET verification = v_arr, updated_at = now() WHERE id = p_id;

  ELSIF p_field = 'priority' THEN
    BEGIN
      v_num := p_value::smallint;
    EXCEPTION WHEN others THEN
      RETURN 'priority-must-be-a-number:'||p_value;
    END;
    UPDATE ledger.ticket SET priority = v_num, updated_at = now() WHERE id = p_id;

  ELSE
    -- ⚠ format(%I) ON THE FIELD NAME, and the field has already been proved to be one of seven
    -- literals by the whitelist above — so this is belt and braces rather than the only guard.
    EXECUTE format('UPDATE ledger.ticket SET %I = $1, updated_at = now() WHERE id = $2', p_field)
      USING p_value, p_id;
  END IF;

  -- ⚠ THE TRACE CARRIES THE PREVIOUS VALUE. Without it a reader can see that something changed and
  -- not what it changed from, which cannot distinguish an authored amendment from a mistake.
  INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
    VALUES (p_id, 'amend', me,
            jsonb_build_object('field', p_field,
                               'from', v_old,
                               'to', p_value,
                               'reason', btrim(p_reason)));

  RETURN 'ok';
END $_$;


--
-- Name: FUNCTION amend_requirement(p_id text, p_field text, p_value text, p_reason text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.amend_requirement(p_id text, p_field text, p_value text, p_reason text) IS 'Amends ONE requirement field of a ticket and records actor/field/previous-value in ledger.ticket_event. Bumps updated_at explicitly, because trg_updated_at_only_on_a_real_change only PRESERVES that column and never sets it. ⚠ Cannot write `status` (returns status-has-its-own-verbs) and writes no owner_override row — an amendment is an ordinary authored change, not the owner beating the file.';


--
-- Name: amendable_fields(); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.amendable_fields() RETURNS text[]
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT ARRAY['title','notes','user_visible_behavior','verification','verification_command',
               'area','priority']::text[]
$$;


--
-- Name: FUNCTION amendable_fields(); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.amendable_fields() IS 'The requirement fields ledger.amend_requirement may write. ⚠ `status` is NOT here and must not be added: lifecycle has its own verbs with their own guards, and a field editor that can also move a status becomes a second writer of one fact. Use groom_to_selected or a lifecycle verb.';


--
-- Name: an_ask_belongs_to_a_park(); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.an_ask_belongs_to_a_park() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM 'parked' AND NEW.park_summary IS NOT NULL THEN
    NEW.park_summary := NULL;
  END IF;
  RETURN NEW;
END $$;


--
-- Name: FUNCTION an_ask_belongs_to_a_park(); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.an_ask_belongs_to_a_park() IS 'A row that is not parked holds no park_summary (188). The ask''s history is in the park events.';


--
-- Name: answer_from_owner(text, text, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.answer_from_owner(p_id text, p_reply text, p_waiting_on text, p_actor text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE
  v_actor text;
  v_kind  text;
  v_was   text;
BEGIN
  -- ── the read-only refusals first: nobody needs authority to be told an answer that writes nothing
  v_actor := nullif(btrim(coalesce(p_actor,'')),'');
  IF v_actor IS NULL THEN RETURN 'refused:no-actor'; END IF;

  -- ⚠ THE REPLY IS THE DELIVERABLE. An empty one would clear his queue and record nothing, which is
  -- the receipt-without-the-answer failure wearing the opposite mask.
  IF nullif(btrim(coalesce(p_reply,'')),'') IS NULL THEN RETURN 'refused:empty-reply'; END IF;

  IF p_waiting_on IS NOT NULL AND p_waiting_on <> 'other' THEN
    RETURN 'refused:answer-clears-to-null-or-other';
  END IF;

  SELECT waiting_on INTO v_was FROM ledger.ticket WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'refused:no-such-ticket'; END IF;
  IF v_was IS DISTINCT FROM 'owner' THEN RETURN 'refused:not-on-the-owner-queue'; END IF;

  -- ⚠ DERIVED, NOT ACCEPTED — see the header. The console is not an agent, so this is 'owner'; an
  -- agent calling it is recorded as an agent, and neither can assert otherwise.
  v_kind := CASE WHEN EXISTS (SELECT 1 FROM ledger.agent WHERE name = session_user::text)
                 THEN 'agent' ELSE 'owner' END;

  INSERT INTO ledger.comment(ticket_id, body, author, author_kind)
  VALUES (p_id, p_reply, v_actor, v_kind);

  UPDATE ledger.ticket
     SET waiting_on = p_waiting_on,
         updated_at = now()
   WHERE id = p_id;

  INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
  VALUES (p_id, 'answer', v_actor,
          jsonb_build_object('from', v_was, 'to', coalesce(p_waiting_on,'null'),
                             'reply_chars', length(p_reply)));

  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN 'refused:' || SQLSTATE || ':' || left(SQLERRM, 120);
END $$;


--
-- Name: FUNCTION answer_from_owner(p_id text, p_reply text, p_waiting_on text, p_actor text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.answer_from_owner(p_id text, p_reply text, p_waiting_on text, p_actor text) IS 'Spec §4. Posts the owner''s reply and takes the ticket off his queue in ONE call — the comment and the waiting_on clear happen together or neither does, because a reply that leaves the row on the queue is the failure the owner queue exists to end. author_kind is derived from session_user and is not forgeable; the author NAME is passed, because the console connects as ledger_console for everybody. Refuses a row that is not on the queue, and refuses to answer one back onto it.';


--
-- Name: append_delivery_note(text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.append_delivery_note(p_id text, p_note text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE
  v_actor text := session_user::text;
  v_note  text := nullif(btrim(coalesce(p_note,'')),'');
  v_before text; v_after text; v_status ledger.ticket_status;
BEGIN
  IF v_note IS NULL THEN RETURN 'refused:empty-note'; END IF;

  SELECT notes, status INTO v_before, v_status FROM ledger.ticket WHERE id = p_id;
  IF NOT FOUND THEN RETURN 'refused:no-such-ticket'; END IF;

  -- ⚠ REFUSED, NOT SKIPPED. A retry and a genuine second note are different events, and a verb that
  -- answers `ok` to both leaves the caller unable to tell which it just did.
  IF coalesce(v_before,'') LIKE '%' || v_note || '%' THEN RETURN 'already-recorded'; END IF;

  UPDATE ledger.ticket
     SET notes = CASE WHEN coalesce(v_before,'') = '' THEN v_note
                      ELSE v_before || E'\n\n' || v_note END,
         updated_at = now()
   WHERE id = p_id;

  -- ⚠ RE-READ RATHER THAN ASSUME. `enforce_owner_override` can replace this write on its way in, and
  -- a verb reporting `ok` for text the database discarded is a landing reported as a take-effect.
  SELECT notes INTO v_after FROM ledger.ticket WHERE id = p_id;
  IF coalesce(v_after,'') NOT LIKE '%' || v_note || '%' THEN
    INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
    VALUES (p_id, 'delivery_note_overridden', v_actor,
            jsonb_build_object('why','an owner_override on notes replaced it', 'note', left(v_note,500)));
    RETURN 'overridden:the owner holds an override on this ticket''s notes — talk to him rather than rewriting it';
  END IF;

  INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
  VALUES (p_id, 'delivery_note', v_actor,
          jsonb_build_object('note', left(v_note,2000), 'status_at_the_time', v_status::text));
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN 'refused:'||SQLSTATE||':'||left(SQLERRM,120);
END $$;


--
-- Name: FUNCTION append_delivery_note(p_id text, p_note text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.append_delivery_note(p_id text, p_note text) IS 'Appends an agent''s delivery note to ledger.ticket.notes. APPENDS, never replaces: a record the next caller can overwrite is the same defect one layer along. Exists because migration 140 stopped the mirror carrying notes from a git file, which is correct for the requirement and removed the only path agents had for the delivery record. An owner_override still wins, deliberately, and the verb re-reads the row and answers `overridden` rather than reporting a write the database discarded.';


--
-- Name: assign_specialism(text, text, text, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.assign_specialism(p_agent text, p_specialism text, p_depth text, p_note text DEFAULT ''::text, p_actor text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE v_actor text; v_proof text; v_evidence ledger.evidence; v_existing ledger.evidence;
BEGIN
  SELECT actor, proof INTO v_actor, v_proof FROM ledger.resolve_actor(p_actor);
  -- The owner and his console speak with his authority; anybody else is reporting behaviour.
  -- Same test `resolve_actor` already uses, so the two cannot disagree about who the console is.
  v_evidence := CASE WHEN session_user::text IN ('ledger_owner','ledger_console')
                     THEN 'declared'::ledger.evidence ELSE 'inferred'::ledger.evidence END;

  IF NOT EXISTS (SELECT 1 FROM ledger.agent WHERE name = p_agent) THEN RETURN 'no-such-agent'; END IF;
  IF EXISTS (SELECT 1 FROM ledger.agent WHERE name = p_agent AND offboarded IS NOT NULL)
    THEN RETURN 'agent-offboarded'; END IF;
  IF NOT EXISTS (SELECT 1 FROM ledger.specialism WHERE name = p_specialism AND retired_at IS NULL)
    THEN RETURN 'no-such-specialism'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
                  WHERE t.typname = 'depth' AND e.enumlabel = p_depth) THEN RETURN 'bad-depth'; END IF;

  -- ⚠ AN AGENT MAY NOT OVERWRITE THE OWNER'S ROW, AND THIS IS THE HALF A GRANT ALONE MISSES.
  -- The INSERT below is an UPSERT, so without this an agent's assign would silently rewrite the
  -- depth, note and provenance of a row the owner had declared -- downgrading his decision to
  -- `inferred` without anybody being told. Refusing by NAME lets the page say why.
  SELECT evidence INTO v_existing FROM ledger.agent_specialism
   WHERE agent = p_agent AND specialism = p_specialism;
  IF v_existing = 'declared' AND v_evidence = 'inferred' THEN RETURN 'declared-is-owner-only'; END IF;

  INSERT INTO ledger.agent_specialism(agent, specialism, depth, declared_by, declared_at, note, evidence)
  VALUES (p_agent, p_specialism, p_depth::ledger.depth, v_actor, now(), coalesce(p_note,''), v_evidence)
  ON CONFLICT (agent, specialism) DO UPDATE SET
    depth = EXCLUDED.depth, declared_by = EXCLUDED.declared_by,
    declared_at = EXCLUDED.declared_at, note = EXCLUDED.note, evidence = EXCLUDED.evidence;

  INSERT INTO ledger.admin_event(entity, entity_id, verb, actor, actor_proof, detail)
  VALUES ('agent', p_agent, 'specialism-assigned', v_actor, v_proof,
          jsonb_build_object('specialism', p_specialism, 'depth', p_depth, 'evidence', v_evidence));
  RETURN 'ok';
END $$;


--
-- Name: claim(text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.claim(p_id text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE t ledger.ticket%ROWTYPE; me text := session_user; v_repair boolean := false;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ledger.agent WHERE name = me AND offboarded IS NULL)
    THEN RETURN 'not-an-active-agent:'||me; END IF;
  SELECT * INTO t FROM ledger.ticket WHERE id = p_id FOR UPDATE;   -- the whole race
  IF NOT FOUND                THEN RETURN 'no-such-ticket'; END IF;
  IF t.status = 'archived'    THEN RETURN 'finished:archived'; END IF;
  IF t.status = 'wont_do'     THEN RETURN 'finished:wont_do'; END IF;
  IF t.claimed_by = me THEN
    -- ⚠ ONLY `selected` IS REPAIRED (PO ruling, 2026-09-28). `selected` is groomed: the PO or the
    -- owner put it on the frontier, so starting it is what a claim is for. `not_started` is the
    -- BACKLOG, off the frontier by design, and reaching `selected` is the PO's move only
    -- (docs/ledger-spec.md §3; raise_ticket refuses a selected raise for the same reason). Repairing
    -- it would let a claim skip grooming, so it is refused, naming the groom as the remedy.
    IF t.status = 'not_started' THEN RETURN 'needs-grooming:not_started (the PO grooms it first: ledger-db.sh groom)'; END IF;
    -- in_progress, parked, or anything else already started: the idempotent answer, nothing written.
    IF t.status <> 'selected' THEN RETURN 'already-yours'; END IF;
    v_repair := true;                                  -- held by me, groomed, never started: repair it below
  ELSIF t.claimed_by IS NOT NULL THEN
    RETURN 'held-by:'||t.claimed_by;
  END IF;
  IF t.status NOT IN ('selected','not_started') THEN RETURN 'not-claimable:'||t.status; END IF;
  IF EXISTS (SELECT 1 FROM unnest(t.depends_on) d JOIN ledger.ticket p ON p.id=d
             WHERE p.status <> 'archived') THEN RETURN 'blocked-on-deps'; END IF;
  IF t.solo AND EXISTS (SELECT 1 FROM ledger.ticket WHERE status='in_progress')
    THEN RETURN 'solo-needs-quiet-board'; END IF;
  UPDATE ledger.ticket SET status='in_progress', claimed_by=me,
         claimed_at = CASE WHEN v_repair THEN coalesce(t.claimed_at, now()) ELSE now() END,
         updated_at=now()
   WHERE id = p_id;
  IF v_repair THEN
    INSERT INTO ledger.ticket_event(ticket_id,verb,actor,detail)
    VALUES (p_id,'claim',me,
            jsonb_build_object('repaired_from', t.status::text,
                               'why', 'the row already named the caller and had never started'));
    RETURN 'ok:repaired-from-'||t.status::text;
  END IF;
  INSERT INTO ledger.ticket_event(ticket_id,verb,actor) VALUES (p_id,'claim',me);
  RETURN 'ok';
END $$;


--
-- Name: clear_mirror_refusal(text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.clear_mirror_refusal(p_id text, p_reason text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE
  t ledger.ticket%ROWTYPE;
  me text := session_user;
BEGIN
  IF nullif(btrim(coalesce(p_reason,'')),'') IS NULL THEN RETURN 'need-reason'; END IF;

  IF NOT EXISTS (SELECT 1 FROM ledger.v_agent WHERE name = me AND role = 'delivery-lead' AND active) THEN
    RETURN 'clearing-a-stamp-is-the-pos-move:'||me;
  END IF;

  SELECT * INTO t FROM ledger.ticket WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'no-such-ticket'; END IF;
  IF t.mirror_refused_at IS NULL THEN RETURN 'not-stamped'; END IF;

  UPDATE ledger.ticket
     SET mirror_refused_at = NULL, mirror_refused_reason = NULL, updated_at = now()
   WHERE id = p_id;

  INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
    VALUES (p_id, 'mirror-refusal-cleared', me,
            jsonb_build_object('reason', btrim(p_reason),
                               'stamp_reason', t.mirror_refused_reason,
                               'stamped_at', t.mirror_refused_at,
                               'via', 'clear_mirror_refusal'));

  RETURN 'ok';
END $$;


--
-- Name: FUNCTION clear_mirror_refusal(p_id text, p_reason text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.clear_mirror_refusal(p_id text, p_reason text) IS 'Clears a mirror-refusal stamp (mirror_refused_at/_reason), putting the row back in reach of v_frontier. Product-owner only, role read from ledger.v_agent. Needs a reason; refuses an unstamped row; records an event carrying the stamp''s own reason and time. After the cutover nothing else can clear a stamp (160 clears only on an accepted mirror from main, which no longer happens).';


--
-- Name: close_as_wont_do(text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.close_as_wont_do(p_id text, p_reason text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE
  t ledger.ticket%ROWTYPE;
  me text := session_user;
BEGIN
  IF nullif(btrim(coalesce(p_reason,'')),'') IS NULL THEN RETURN 'need-reason'; END IF;

  IF NOT EXISTS (SELECT 1 FROM ledger.v_agent WHERE name = me AND role = 'delivery-lead' AND active) THEN
    RETURN 'wont-do-is-the-pos-call:'||me;
  END IF;

  SELECT * INTO t FROM ledger.ticket WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'no-such-ticket'; END IF;
  IF t.status = 'wont_do' THEN RETURN 'already:wont_do'; END IF;
  IF t.status IN ('passing','archived') THEN RETURN 'delivered-work-is-not-wont-do:'||t.status::text; END IF;

  UPDATE ledger.ticket
     SET status = 'wont_do',
         parked_reason = NULL, parked_at = NULL, parked_by = NULL, park_kind = NULL,
         updated_at = now()
   WHERE id = p_id;

  INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
    VALUES (p_id, 'status', me,
            jsonb_build_object('from', t.status::text, 'to', 'wont_do', 'reason', btrim(p_reason),
                               'via', 'close_as_wont_do')
            || CASE WHEN t.status = 'parked'
                    THEN jsonb_build_object('was_parked',
                           jsonb_build_object('reason', t.parked_reason, 'by', t.parked_by,
                                              'at', t.parked_at, 'kind', t.park_kind::text))
                    ELSE '{}'::jsonb END);

  RETURN 'ok';
END $$;


--
-- Name: FUNCTION close_as_wont_do(p_id text, p_reason text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.close_as_wont_do(p_id text, p_reason text) IS 'The PO closes a ticket as won''t-do (docs/ledger-spec.md §3, any -> wont_do, with a reason). Product-owner only, role read from ledger.v_agent. Refuses passing/archived (delivered work). From parked, clears the four park columns migration 58 guards and records the prior park in the event. Leaves claimed_by so the holder can still release.';


--
-- Name: create_draft_ticket(text, text, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.create_draft_ticket(p_id text, p_title text, p_area text DEFAULT 'infra'::text, p_body text DEFAULT ''::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $_$
DECLARE v_actor text := session_user::text; v_area text := coalesce(nullif(btrim(p_area),''),'infra');
BEGIN
  -- ⚠ THE ACTOR IS session_user AND IS NOT A PARAMETER, exactly as `ledger.claim` takes it. A WHO
  -- argument is what lets one caller act as another, and ownership is the one field nothing
  -- downstream can correct. SECURITY DEFINER does not interfere: it changes CURRENT_USER, while
  -- session_user stays the login role that actually called in.
  -- ⚠ NOT `ledger.resolve_actor(NULL)` — that returns TABLE(actor, proof), not a scalar, so the
  -- assignment my first draft used would have failed at runtime on every call. Caught by reading
  -- pg_get_function_result rather than by trusting that the name meant what it sounded like.
  IF nullif(btrim(coalesce(p_id,'')),'') IS NULL THEN RETURN 'no-id'; END IF;
  IF p_id !~ '^[a-z][a-z0-9_-]{4,200}$' THEN RETURN 'bad-id'; END IF;
  IF length(coalesce(btrim(p_title),'')) < 8 THEN RETURN 'title-too-short'; END IF;
  IF EXISTS (SELECT 1 FROM ledger.ticket WHERE id = p_id) THEN RETURN 'exists'; END IF;
  IF NOT EXISTS (SELECT 1 FROM ledger.area WHERE name = v_area) THEN
    -- ⚠ REFUSE, DO NOT COERCE. `mirror_ticket` coerces an unknown area to `infra` because it is
    -- copying a file that already exists and must not lose the row. Here the owner is typing it and
    -- can be told, so silently storing the value that means "we did not know" would be worse.
    RETURN 'unknown-area:' || v_area;
  END IF;
  -- ⚠ claimed_by IS NULL AND status IS draft: `owned_iff_in_progress` is
  -- ((status = 'in_progress') = (claimed_by IS NOT NULL)) -> (false) = (false) -> TRUE, so this
  -- satisfies the CHECK with no relaxation. That constraint is what makes the two worst states
  -- unrepresentable and nothing here weakens it. The self-test asserts the CHECK still bites.
  INSERT INTO ledger.ticket(id, title, area, status, user_visible_behavior, raised_by)
  VALUES (p_id, btrim(p_title), v_area, 'draft', coalesce(p_body,''), v_actor);
  INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
  VALUES (p_id, 'drafted', v_actor, jsonb_build_object('area', v_area));
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN 'refused:' || SQLSTATE || ':' || left(SQLERRM, 120);
END $_$;


--
-- Name: FUNCTION create_draft_ticket(p_id text, p_title text, p_area text, p_body text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.create_draft_ticket(p_id text, p_title text, p_area text, p_body text) IS 'The ONLY path that creates a ledger ticket. Owner-only by GRANT (ledger_console); lands the row at status=draft with claimed_by NULL, which satisfies owned_iff_in_progress unchanged. Before migration 35 nothing in this database could create a ticket at all — every other write mutated an existing row or arrived through mirror_ticket from a git file.';


--
-- Name: dismiss_request(bigint, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.dismiss_request(p_seq bigint, p_reason text, p_actor text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE v_actor text; v_proof text; v_state text;
BEGIN
  SELECT actor, proof INTO v_actor, v_proof FROM ledger.resolve_actor(p_actor);
  -- ⚠ A REASON IS THE PRICE OF DISMISSAL. Without it this becomes the silent drain the table exists
  -- to remove, wearing a different hat — the item still vanishes, just with a click instead of a
  -- forgetting. The CHECK constraint enforces it too; this returns a verdict the screen can show.
  IF btrim(coalesce(p_reason,'')) = '' THEN RETURN 'reason-required'; END IF;
  SELECT CASE WHEN ticket_id IS NOT NULL THEN 'ticketed'
              WHEN dismissed_at IS NOT NULL THEN 'dismissed' ELSE 'outstanding' END
    INTO v_state FROM ledger.request WHERE seq = p_seq;
  IF v_state IS NULL THEN RETURN 'no-such-request'; END IF;
  IF v_state <> 'outstanding' THEN RETURN 'already-' || v_state; END IF;
  UPDATE ledger.request
     SET dismissed_at = now(), dismissed_by = v_actor, dismissed_reason = p_reason
   WHERE seq = p_seq;
  INSERT INTO ledger.admin_event(entity, entity_id, verb, actor, actor_proof)
  VALUES ('request', p_seq::text, 'dismissed', v_actor, v_proof);
  RETURN 'dismissed';
END $$;


--
-- Name: drift_original(text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.drift_original(p_id text, p_field text) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE
  v_vals text[];
BEGIN
  SELECT array_agg(DISTINCT d.found) INTO v_vals
    FROM ledger.import_drift d
    JOIN ledger.ticket t ON t.id = d.id
   WHERE d.entity = 'ticket' AND d.id = p_id AND d.field = p_field
     -- the three arms of migration 66, verbatim; see the warning above before changing either copy
     AND (  (d.field <> ALL (ARRAY['mirror_refused','status']) AND d.at = t.updated_at)
         OR (d.field = 'mirror_refused' AND t.mirror_refused_at IS NOT NULL)
         OR (d.field = 'status'         AND t.status::text = 'archived') );

  IF v_vals IS NULL OR array_length(v_vals,1) = 0 THEN RETURN NULL; END IF;
  IF array_length(v_vals,1) > 1 THEN
    RAISE EXCEPTION
      'ambiguous recorded original for %.%: % current values (%). Nothing here can choose between '
      'them -- a tie-break would pick one silently, which is the defect this function exists to '
      'refuse. Resolve the corpus, or read ledger.import_drift directly and say in the caller which '
      'rule you are applying and why.',
      p_id, p_field, array_length(v_vals,1), array_to_string(v_vals, ' | ')
      USING ERRCODE = 'data_exception';
  END IF;
  RETURN v_vals[1];
END
$$;


--
-- Name: FUNCTION drift_original(p_id text, p_field text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.drift_original(p_id text, p_field text) IS 'The one recorded original for (id, field), or NULL if none is current. RAISES on more than one rather than tie-breaking. ⚠ Not for the archived terminal status -- that has its own column, ledger.ticket.archived_from_status, since migration 148.';


--
-- Name: enforce_owner_override(); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.enforce_owner_override() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE r record; incoming text;
BEGIN
  FOR r IN SELECT field, value FROM ledger.owner_override WHERE ticket_id = NEW.id LOOP
    incoming := CASE r.field
                  WHEN 'priority'              THEN NEW.priority::text
                  WHEN 'area'                  THEN NEW.area
                  WHEN 'status'                THEN NEW.status::text
                  WHEN 'title'                 THEN NEW.title
                  WHEN 'user_visible_behavior' THEN NEW.user_visible_behavior
                  WHEN 'notes'                 THEN NEW.notes
                  WHEN 'verification'          THEN NEW.verification::text
                  WHEN 'verification_command'  THEN NEW.verification_command
                END;
    IF incoming IS NOT DISTINCT FROM r.value THEN
      -- ⚠ GIT HAS CAUGHT UP, SO THE OVERRIDE HAS DONE ITS JOB AND MUST GO. Without this the two
      -- stores never reconverge and the table grows for ever -- an override that cannot retire is a
      -- permanent fork wearing the costume of a temporary one.
      DELETE FROM ledger.owner_override WHERE ticket_id = NEW.id AND field = r.field;
      INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
        VALUES (NEW.id, 'override_retired', 'system',
                jsonb_build_object('field', r.field, 'value', left(r.value, 500), 'why', 'git caught up'));
    ELSE
      CASE r.field
        WHEN 'priority'              THEN NEW.priority              := r.value::smallint;
        WHEN 'area'                  THEN NEW.area                  := r.value;
        WHEN 'status'                THEN NEW.status                := r.value::ledger.ticket_status;
        WHEN 'title'                 THEN NEW.title                 := r.value;
        WHEN 'user_visible_behavior' THEN NEW.user_visible_behavior := r.value;
        WHEN 'notes'                 THEN NEW.notes                 := r.value;
        WHEN 'verification'          THEN NEW.verification          := r.value::text[];
        WHEN 'verification_command'  THEN NEW.verification_command  := r.value;
      END CASE;
    END IF;
  END LOOP;
  RETURN NEW;
END $$;


--
-- Name: flip_passing(text, integer); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.flip_passing(p_id text, p_pr integer) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE t ledger.ticket%ROWTYPE; me text := session_user;
BEGIN
  IF p_pr IS NULL THEN RETURN 'unstamped'; END IF;
  SELECT * INTO t FROM ledger.ticket WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'no-such-ticket'; END IF;
  IF t.claimed_by IS DISTINCT FROM me THEN RETURN 'not-yours:'||coalesce(t.claimed_by,'(unclaimed)'); END IF;
  UPDATE ledger.ticket SET status='passing', claimed_by=NULL, claimed_at=NULL,
         parked_reason=NULL, parked_at=NULL, parked_by=NULL, verified_by_pr=p_pr,
         delivered_by=me, updated_at=now()
   WHERE id=p_id;
  INSERT INTO ledger.ticket_event(ticket_id,verb,actor,detail)
    VALUES (p_id,'flip_passing',me,jsonb_build_object('pr',p_pr));
  RETURN 'ok';
END $$;


--
-- Name: groom_to_selected(text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.groom_to_selected(p_id text, p_reason text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE
  t ledger.ticket%ROWTYPE;
  me text := session_user;
BEGIN
  IF nullif(btrim(coalesce(p_reason,'')),'') IS NULL THEN RETURN 'need-reason'; END IF;

  -- ⚠ THE ROLE IS READ FROM THE ROSTER, NEVER HARDCODED. The delivery-lead role has changed hands,
  -- and a name written here would be a fact in two places with the copy in the database winning
  -- silently. Same rule the `po-owner` verb already follows.
  IF NOT EXISTS (SELECT 1 FROM ledger.v_agent WHERE name = me AND role = 'delivery-lead' AND active) THEN
    RETURN 'ready-is-the-pos-move:'||me;
  END IF;

  SELECT * INTO t FROM ledger.ticket WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'no-such-ticket'; END IF;
  IF t.status = 'selected' THEN RETURN 'already:selected'; END IF;

  -- ⚠ ONLY FROM THE BACKLOG. Grooming is `— → ready`; pulling a ticket that is in_progress, parked,
  -- passing or archived BACK onto the frontier is a different act with different consequences (it
  -- would orphan a live claim), and it is not what the spec's missing row describes.
  IF t.status <> 'not_started' THEN RETURN 'not-groomable-from:'||t.status::text; END IF;

  UPDATE ledger.ticket SET status = 'selected', updated_at = now() WHERE id = p_id;

  INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
    VALUES (p_id, 'status', me,
            jsonb_build_object('from', t.status::text, 'to', 'selected',
                               'reason', btrim(p_reason), 'via', 'groom_to_selected'));

  RETURN 'ok';
END $$;


--
-- Name: FUNCTION groom_to_selected(p_id text, p_reason text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.groom_to_selected(p_id text, p_reason text) IS 'Performs the PO transition docs/ledger-spec.md §3 allows and no verb implemented: not_started -> selected, feeding the ready frontier init.sh reads. Product-owner only, role read from ledger.v_agent rather than hardcoded. Refuses any source status other than not_started.';


--
-- Name: import_legacy_ticket(jsonb, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.import_legacy_ticket(p jsonb, p_source text DEFAULT 'feature_list.archive.jsonl'::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE
  v_id      text := p->>'id';
  v_existing text;
  v_found   boolean;
  v_verdict text;
BEGIN
  IF v_id IS NULL OR v_id = '' THEN RETURN 'no-id'; END IF;

  SELECT legacy_source, true INTO v_existing, v_found
    FROM ledger.ticket WHERE id = v_id;

  -- A row that exists and did NOT come from a legacy store is a live ticket. Refuse, record, return.
  IF v_found IS TRUE AND v_existing IS NULL THEN
    INSERT INTO ledger.import_drift(entity, id, field, found, note)
    VALUES ('ticket', v_id, 'legacy_source', p_source,
            'id exists in the legacy store AND as a native row; the native row was left untouched');
    RETURN 'native-row-exists';
  END IF;

  v_verdict := ledger.mirror_ticket(p);

  -- ⚠ STAMP ONLY ON A CLEAN MIRROR. `mirror_ticket` returns 'ok' or a reason; stamping a refused
  -- row would mark a legacy import that never landed, and the refusal reason is what the caller
  -- needs to report. An unstamped row cannot be mistaken for an imported one.
  IF v_verdict = 'ok' THEN
    UPDATE ledger.ticket SET legacy_source = p_source WHERE id = v_id;
  END IF;

  RETURN v_verdict;
END
$$;


--
-- Name: is_probe(text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.is_probe(p_id text) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$ SELECT p_id IS NOT NULL AND p_id LIKE 'zz\_%' $$;


--
-- Name: FUNCTION is_probe(p_id text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.is_probe(p_id text) IS 'True for a test-probe ticket id. THE single definition of the zz_ convention — views and scripts/check-ledger-has-no-probe-rows.sh both call this rather than spelling the pattern. Note the escaped underscore: a bare _ in LIKE is a wildcard.';


--
-- Name: link_request(bigint, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.link_request(p_seq bigint, p_ticket text, p_actor text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE v_actor text; v_proof text; v_state text;
BEGIN
  SELECT actor, proof INTO v_actor, v_proof FROM ledger.resolve_actor(p_actor);
  SELECT CASE WHEN ticket_id IS NOT NULL THEN 'ticketed'
              WHEN dismissed_at IS NOT NULL THEN 'dismissed' ELSE 'outstanding' END
    INTO v_state FROM ledger.request WHERE seq = p_seq;
  IF v_state IS NULL THEN RETURN 'no-such-request'; END IF;
  -- ⚠ REFUSE TO RE-DECIDE A SETTLED REQUEST. Quietly relinking one already ticketed, or resurrecting
  -- a dismissed one, would change the denominator without anybody seeing it happen.
  IF v_state <> 'outstanding' THEN RETURN 'already-' || v_state; END IF;
  IF NOT EXISTS (SELECT 1 FROM ledger.ticket WHERE id = p_ticket) THEN RETURN 'no-such-ticket'; END IF;
  UPDATE ledger.request SET ticket_id = p_ticket WHERE seq = p_seq;
  INSERT INTO ledger.admin_event(entity, entity_id, verb, actor, actor_proof)
  VALUES ('request', p_seq::text, 'linked:' || p_ticket, v_actor, v_proof);
  RETURN 'linked';
END $$;


--
-- Name: log_extra_key_withdrawal(); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.log_extra_key_withdrawal() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE
  k text;
BEGIN
  FOR k IN SELECT jsonb_object_keys(coalesce(OLD.extra,'{}'::jsonb)) LOOP
    IF NOT (coalesce(NEW.extra,'{}'::jsonb) ? k)
       OR (NEW.extra -> k) IS DISTINCT FROM (OLD.extra -> k) THEN
      INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
      VALUES (OLD.id, 'extra_key_withdrawn', session_user::text,
              jsonb_build_object(
                'key',      k,
                'was',      OLD.extra -> k,
                'now',      NEW.extra -> k,
                'removed',  NOT (coalesce(NEW.extra,'{}'::jsonb) ? k)));
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;


--
-- Name: mirror_ticket(jsonb); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.mirror_ticket(p jsonb) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE
  v_id text := p->>'id';
  v_status text := coalesce(p->>'status','not_started');
  v_owner text := nullif(p->>'claimed_by','');
  -- ⚠ READ THE FILE'S OWN parked_by. It was never read: `parked_by` was DERIVED from v_owner
  -- (i.e. from claimed_by) further down, so a ticket parked by someone who had not also
  -- claimed it recorded no parker at all.
  v_parked_by text := nullif(p->>'parked_by','');
  -- An in-progress ticket's owner may sit in EITHER field. `park` keeps in_progress by design.
  v_any_owner text := coalesce(nullif(p->>'claimed_by',''), nullif(p->>'parked_by',''));
  v_area text := coalesce(nullif(p->>'area',''),'infra');
  -- The status the DATABASE currently holds for this id -- NOT the payload's. The guard
  -- below is the only thing in this function that reads the existing row before writing it.
  v_held ledger.ticket_status;
  -- ⚠ THE OWNER THE DATABASE CURRENTLY HOLDS -- captured BEFORE the upsert, because the ON CONFLICT
  -- arm cannot report what it decided and the drift row below has to name it. (migration 104)
  v_held_owner text;
  -- 'true' | 'false' | NULL. NULL is CANNOT TELL and is not the same as 'false'.
  v_lock text := nullif(p->>'lock_held','');
  -- ⚠ THE ROW'S updated_at BEFORE AND AFTER THE UPSERT. This pair is the ONLY thing that decides
  -- whether a 'mirrored' event is written, and it is a READ of the suppression trigger's verdict
  -- rather than a second copy of it -- see migration 108's header for why that matters.
  -- NULL `before` means there was no row: a genuine INSERT, which always counts as a change.
  v_before_updated timestamptz;
  v_after_updated  timestamptz;
  -- ⚠ THE REQUIREMENT THE ROW ALREADY HOLDS. Read BEFORE the upsert, because after it the row is
  -- whatever we just wrote and the comparison would be against ourselves (migration 25's defect,
  -- one layer up, and the reason retire_satisfied_overrides runs before the INSERT too).
  v_row_exists boolean := false;
  v_row_title text; v_row_notes text; v_row_uvb text;
  v_row_verif text[]; v_row_vcmd text;
  -- ⚠ THE THREE FIELDS THAT HAD NO `v_row_*` AT ALL, WHICH IS WHY THEY COULD NOT DRIFT.
  -- Their clause below claimed the disagreement was "RECORDED as drift instead"; there was nothing
  -- to compare against, so it never was. (migration 160)
  v_row_evidence text; v_row_acceptance text[]; v_row_lvc text;
  v_drifted text[] := ARRAY[]::text[];
BEGIN
  -- ⚠ THE ID CHECK MOVED ABOVE THE RETIREMENT, AND THAT IS A DELIBERATE BEHAVIOUR CHANGE.
  -- You cannot look a row up without an id, and the draft guard below has to read the row. The
  -- consequence is stated rather than hidden: a payload we are about to REFUSE no longer runs
  -- retire_satisfied_overrides first. That is the correct order -- retiring an override means
  -- "git has caught up", and git has not caught up with a row it does not own.
  IF v_id IS NULL OR v_id = '' THEN RETURN 'no-id'; END IF;

  -- ── THE GUARD ───────────────────────────────────────────────────────────────────────
  -- ⚠ THE ENUM VALUE WITHOUT THIS GUARD IS DECORATION. `status` is one of the three fields written
  -- UNCONDITIONALLY by the ON CONFLICT clause below (migration 30 -- a decision, not an oversight),
  -- and `v_status` above defaults to `not_started` when the payload carries no status key at all.
  -- So a draft is reset by ANY payload for its id, including one that never mentions status.
  --
  -- ⚠ DRIVEN BEFORE THIS MIGRATION WAS WRITTEN, on a throwaway instance built from this directory:
  --     seed  zz_drive_subject at status=selected        -> row reads `selected`   (eligible)
  --     mirror {"id":..., "title":..., "area":...}       -> verdict `ok`
  --     row now reads                                       `not_started`   ← THE DEFECT
  --     control: the same payload carrying status=selected -> row stays `selected`
  -- The payload with NO status key is the case that fails; a payload WITH one demonstrates nothing,
  -- because keeping git's stated status is the pre-existing behaviour this file is not changing.
  --
  -- ⚠ IT REFUSES, IT DOES NOT SKIP. 14-a-refused-mirror-leaves-a-mark.sql exists because a silent
  -- skip is two stores disagreeing with no record of the disagreement.
  --
  -- ⚠ AND THE REFUSAL IS RARE BY CONSTRUCTION, WHICH IS WHAT MAKES `_mark_refused` SAFE HERE.
  -- `sync` builds its payloads from `git ls-tree -r <ref> features/` (ledger-db.sh:407) -- GIT FILES
  -- ONLY. A draft is database-only and has no file, so no payload is ever built for it and this
  -- branch does not fire on a routine sync. That matters: a guard that refused on every sync would
  -- put a permanent row into `v_mirror_refused`, whose meaning on the board is "this row did NOT
  -- land and the OLD one is still being routed from" -- false for a draft, and it would blind the
  -- card exactly as an owner_override on a draft would blind `v_owner_override_pending`. Same
  -- defect shape, third place it could have been introduced in this one ticket.
  --
  -- WHEN IT DOES FIRE it means something genuinely wrong: an id drafted in the database that also
  -- exists as a ticket file in git, or a hand-built `mirror` call. Both deserve a mark.
  SELECT status, claimed_by, updated_at, title, notes, user_visible_behavior, verification, verification_command,
         evidence, acceptance, last_verified_commit
    INTO v_held, v_held_owner, v_before_updated,
         v_row_title, v_row_notes, v_row_uvb, v_row_verif, v_row_vcmd,
         v_row_evidence, v_row_acceptance, v_row_lvc
    FROM ledger.ticket WHERE id = v_id;
  v_row_exists := FOUND;
  IF v_held IN ('draft','reviewed') THEN
    PERFORM ledger._mark_refused(v_id, 'held-by-the-database:' || v_held::text);
    RETURN 'held-by-the-database:' || v_held::text;
  END IF;
  -- ⚠⚠ A SOURCE THAT IS NOT origin/main MAY CREATE A ROW AND MAY NOT UPDATE ONE ───────────────────
  --
  -- DRIVEN 2026-09-17 (infra_the_git_to_ledger_refresh_overwrites_a_current_row_from_a_stale_ref).
  -- Every lifecycle verb refreshes the row from git BEFORE it judges anything, and the copy it
  -- refreshes from is whichever ref happens to carry the ticket file. Measured against a throwaway:
  -- a row holding current values, a branch tip holding a months-old copy, `claim` run, and TEN of
  -- the eighteen git-owned fields took the stale ref's values -- area, status, priority, parent,
  -- depends_on, solo, raised_by, issue, verified_by_pr, extra. The requirement prose survived;
  -- the structure and the lifecycle did not.
  --
  -- ⚠ THE REACHABLE SET IS BRANCH TIPS, WHICH IS WIDER THAN IT SOUNDS AND NARROWER THAN IT WAS
  -- FIRST REPORTED. Driven: a remote branch named nothing like the ticket id is a write path, and
  -- so is a LOCAL branch that was never pushed. A file in main's HISTORY alone is NOT -- the
  -- resolver reads ref tips, so a merged-and-deleted branch carries nothing. The set is therefore
  -- prunable in principle and not prunable centrally, because nothing on the remote side can see a
  -- local ref.
  --
  -- ⚠ THE GUARD ABOVE THIS ONE IS NOT THE FIX AND WAS NEVER BROKEN. `ledger_mirror_prefer_ref`
  -- prefers origin/main's blob over the working tree's when BOTH exist and they differ, and it
  -- works: driven with the row, main and a ref all disagreeing, main won both contested fields.
  -- WHAT STEP 7 REMOVES IS NOT THE GUARD BUT ITS PRECONDITION. With the ticket files gone from
  -- main, "prefer main" has nothing to prefer and every caller falls through to the ref.
  --
  -- So the rule is about PROVENANCE rather than about content: a payload that says where it came
  -- from, and did not come from main, may INSERT a row the database does not have and may not
  -- overwrite one it does.
  --
  -- ⚠ ABSENT `source` KEEPS TODAY'S BEHAVIOUR, DELIBERATELY. Migration 080's park round-trip and
  -- migration 141's legacy import both call this function with legitimate updates that do not come
  -- from main; defaulting an unstated source to 'ref' would refuse them. Only a caller that KNOWS
  -- its provenance says so, and `ledger-db.sh mirror` is the one that does.
  IF v_row_exists AND nullif(p->>'source','') IS NOT NULL AND p->>'source' <> 'main' THEN
    PERFORM ledger._mark_refused(v_id, 'not-main:' || (p->>'source'));
    RETURN 'not-main:the row exists and this payload did not come from origin/main — insert-only';
  END IF;

  -- ⚠ RETIREMENT LIVES HERE, NOT IN THE TRIGGER, AND IT MUST RUN BEFORE THE UPSERT.
  -- Only this function knows what GIT said; the trigger sees only a row it may itself have
  -- written. Running it after the upsert would compare git's value against the override the
  -- trigger had just re-applied -- migration 25's defect, one layer up.
  -- (epic_phase_4_the_ledger_database_becomes_authoritative, migration 26)
  PERFORM ledger.retire_satisfied_overrides(p);

  IF NOT EXISTS (SELECT 1 FROM ledger.area WHERE name = v_area) THEN
    -- ⚠ TRY THE SYNONYM MAP FIRST. It existed in agents/areas.json for weeks and this function had
    -- never opened it, so resolvable aliases were being coerced to `infra` alongside genuinely
    -- unknown ones — two different facts recorded as the same drift row.
    DECLARE v_mapped text;
    BEGIN
      SELECT area INTO v_mapped FROM ledger.area_synonym WHERE alias = v_area;
      IF v_mapped IS NOT NULL THEN
        -- Still drift: the ticket names something off the controlled list. But it is RESOLVED
        -- drift, and saying which is the difference between "we fixed it" and "we gave up".
        INSERT INTO ledger.import_drift(entity,id,field,found,note)
        VALUES ('ticket', v_id, 'area', v_area, 'a known synonym; resolved to ' || v_mapped);
        v_area := v_mapped;
      ELSE
        -- ⚠ RECORD IT, DO NOT COERCE IT SILENTLY. An off-list area is how the taxonomy rots, and an
        -- unresolvable one needs a human to say what it means — see 01b.
        INSERT INTO ledger.import_drift(entity,id,field,found,note)
        VALUES ('ticket', v_id, 'area', v_area, 'off the controlled list and not a known synonym; stored as infra');
        v_area := 'infra';
      END IF;
    END;
  END IF;
  -- ⚠ EITHER FIELD IS AN OWNER. This tested claimed_by alone and refused 10 of 2250 rows on every
  -- sync — measured against origin/main: ALL of them were PARKED with a reason and an owner in
  -- parked_by, and ZERO were genuinely ownerless. A parked ticket keeps `in_progress` because
  -- that is what `feature-ticket.sh park` does, deliberately, to hold the lock.
  -- ⚠ AND THE REFUSAL DID NOT LEAVE A HOLE, IT LEFT THE OLD ROW — so a ticket already on the
  -- board kept a STALE status, and v_frontier once offered a locked, parked ticket as claimable.
  IF v_status = 'in_progress' AND v_any_owner IS NULL THEN
    PERFORM ledger._mark_refused(v_id, 'in-progress-without-an-owner');
    RETURN 'in-progress-without-an-owner';
  END IF;
  IF v_owner IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ledger.agent WHERE name = v_owner) THEN
    INSERT INTO ledger.import_drift(entity,id,field,found,note)
    VALUES ('ticket', v_id, 'claimed_by', v_owner, 'not in the roster at mirror time; owner dropped');
    v_owner := NULL;
    IF v_status = 'in_progress' THEN
      PERFORM ledger._mark_refused(v_id, 'owner-not-in-roster');
      RETURN 'owner-not-in-roster';
    END IF;
  END IF;


  -- ⚠ RECORD A PRIORITY THIS SCHEMA CANNOT RESOLVE. Until now `priority_of` returned 3 for an
  -- unresolvable value and 3 for `medium`, so nothing downstream could tell them apart and the
  -- coercion left no trace. `priority_of_strict` returns NULL for exactly the values the mapping does
  -- not cover, which is what makes this row writable at all.
  --
  -- ⚠ IT RECORDS AND CARRIES ON — it does NOT refuse. Refusing would set `mirror_refused_at`, and
  -- `v_frontier` filters on that being NULL, so the ticket would drop off the ready frontier
  -- entirely: a RANKING bug turned into a HIDING bug. 19's header is the sentence that forbids it —
  -- "it ranks wrong; it does not yet hide anything, and saying which of those two it is matters" —
  -- and 17 and 21 say the same thing from two other directions.
  --
  -- ⚠ `p ? 'priority'` MATTERS: a caller that sends no priority at all is not drift. An unstated
  -- priority meaning the column default is what the schema already says, and recording that would
  -- bury the real ones under thousands of rows that mean nothing.
  IF p ? 'priority' AND ledger.priority_of_strict(p->>'priority') IS NULL THEN
    INSERT INTO ledger.import_drift(entity,id,field,found,note)
    VALUES ('ticket', v_id, 'priority', left(coalesce(p->>'priority',''),100),
            'unresolvable; stored as the column default (3). The ticket still mirrors and stays on the frontier -- it ranks wrong, it is not hidden.');
  END IF;
  -- ⚠ `array_append`, NOT `||`. `text[] || 'literal'` resolves the unknown-typed literal as an
  -- ARRAY literal, so the first drive of this function died with
  --     refused:22P02:malformed array literal: "title"
  -- ⚠⚠ AND THAT FAILURE PRESENTED AS A PASS. The abort happened BEFORE the upsert, so the row was
  -- unchanged and my "the file did not move the row" assertion read GREEN — about a function that
  -- had refused the payload outright. An assertion that the row did not change is worth nothing
  -- unless the write was actually attempted; the verdict string is what caught it.
  --
  -- ⚠⚠ THE ROW WINS, AND GIT'S ATTEMPT IS RECORDED RATHER THAN SWALLOWED.
  -- Preserving silently would be the INVERSE of the defect fixed this morning: there, git's PRESENCE
  -- erased a value the owner set; here, the row's precedence would erase a value an author typed
  -- into a file, with nothing to see. One store winning over another with no record of the
  -- disagreement is the shape this schema has been bitten by in BOTH directions.
  IF v_row_exists THEN
    IF p ? 'title'                 AND nullif(p->>'title','')                 IS DISTINCT FROM v_row_title THEN v_drifted := array_append(v_drifted, 'title'); END IF;
    IF p ? 'notes'                 AND coalesce(p->>'notes','')               IS DISTINCT FROM coalesce(v_row_notes,'') THEN v_drifted := array_append(v_drifted, 'notes'); END IF;
    IF p ? 'user_visible_behavior' AND coalesce(p->>'user_visible_behavior','') IS DISTINCT FROM coalesce(v_row_uvb,'') THEN v_drifted := array_append(v_drifted, 'user_visible_behavior'); END IF;
    IF p ? 'verification_command'  AND nullif(p->>'verification_command','')  IS DISTINCT FROM v_row_vcmd THEN v_drifted := array_append(v_drifted, 'verification_command'); END IF;
    IF p ? 'verification' AND jsonb_typeof(p->'verification') = 'array'
       AND ARRAY(SELECT jsonb_array_elements_text(p->'verification')) IS DISTINCT FROM coalesce(v_row_verif,'{}') THEN v_drifted := array_append(v_drifted, 'verification'); END IF;
    -- ⚠ THE THREE THE COMMENT ALREADY PROMISED. Only when the row HOLDS something: a row with no
    -- value is not in disagreement with the file, it is empty, and the clause below now fills it.
    -- Recording that as drift would turn every ordinary first write into a drift row and bury the
    -- real ones — the failure mode of a detector nobody can read. (migration 160)
    IF p ? 'evidence' AND v_row_evidence IS NOT NULL
       AND nullif(p->>'evidence','') IS DISTINCT FROM v_row_evidence THEN v_drifted := array_append(v_drifted, 'evidence'); END IF;
    IF p ? 'last_verified_commit' AND v_row_lvc IS NOT NULL
       AND nullif(p->>'last_verified_commit','') IS DISTINCT FROM v_row_lvc THEN v_drifted := array_append(v_drifted, 'last_verified_commit'); END IF;
    IF p ? 'acceptance' AND jsonb_typeof(p->'acceptance') = 'array'
       AND coalesce(array_length(v_row_acceptance,1),0) > 0
       AND ARRAY(SELECT jsonb_array_elements_text(p->'acceptance')) IS DISTINCT FROM v_row_acceptance THEN v_drifted := array_append(v_drifted, 'acceptance'); END IF;

    IF array_length(v_drifted,1) IS NOT NULL THEN
      INSERT INTO ledger.import_drift(entity,id,field,found,note)
      SELECT 'ticket', v_id, f, 'git differs from the row',
             'the DATABASE is authoritative for the requirement since migration 140; the file''s value was NOT applied. '
             'If the file is right, the fix is to change the row (the console, or owner_set_field) and let export regenerate the file.'
        FROM unnest(v_drifted) f;
    END IF;
  END IF;

  INSERT INTO ledger.ticket(id, title, area, status, claimed_by, claimed_at,
                            parked_reason, parked_at, parked_by, park_summary, verified_by_pr, issue,
                            priority, depends_on, solo, parent, raised_by, notes,
                            user_visible_behavior, verification, verification_command, extra,
                            claimed_by_carried, archived_from_status,
                            evidence, acceptance, last_verified_commit)
  VALUES (v_id, coalesce(p->>'title', v_id), v_area, v_status::ledger.ticket_status, v_owner,
          CASE WHEN v_owner IS NOT NULL THEN now() END,
          nullif(p->>'parked_reason',''),
          CASE WHEN nullif(p->>'parked_reason','') IS NOT NULL THEN now() END,
          -- ⚠ THE FILE'S parked_by, falling back to the claimant only when the file omits it.
          CASE WHEN nullif(p->>'parked_reason','') IS NOT NULL THEN coalesce(v_parked_by, v_owner) END,
          -- park_summary (187 restores 080's arm, dropped by 093): the file's ask, or NULL. On INSERT
          -- there is no prior row to preserve.
          nullif(p->>'park_summary',''),
          (nullif(p->>'verified_by_pr',''))::int, (nullif(p->>'issue',''))::int,
          -- On INSERT a missing key becomes the column default (3), which is what the schema already
          -- says an unstated priority means. On UPDATE it is left alone -- see the ON CONFLICT note.
          ledger.priority_of(p->>'priority'),
          -- ⚠ depends_on is a jsonb ARRAY in the file and a text[] in the column. `jsonb_array_elements_text`
          -- over a NON-array raises, so the shape is tested first: a ticket whose depends_on was
          -- hand-edited to a bare string must mirror as empty, not abort the whole sync.
          coalesce(CASE WHEN jsonb_typeof(p->'depends_on') = 'array'
               THEN ARRAY(SELECT jsonb_array_elements_text(p->'depends_on')) END, '{}'),
          -- The file omits `solo` far more often than it sets it, and omitted means false.
          coalesce((p->>'solo')::boolean, false),
          nullif(p->>'parent',''), nullif(p->>'raised_by',''),
          -- ⚠ `notes` IS A text COLUMN AND THE FILES CARRY BOTH SHAPES. Some tickets hold a string,
          -- others a list -- I hit a list-valued `notes` by hand today and it threw. A jsonb array
          -- reaching `->>` would arrive as its raw JSON text, storing "[\"a\", \"b\"]" as prose, so an
          -- array is joined into paragraphs instead.
          coalesce(CASE WHEN jsonb_typeof(p->'notes') = 'array'
               THEN array_to_string(ARRAY(SELECT jsonb_array_elements_text(p->'notes')), E'\n\n')
               ELSE p->>'notes' END, ''),
          coalesce(p->>'user_visible_behavior', ''),
          -- ⚠ AND `verification` IS THE MIRROR IMAGE: a text[] COLUMN fed by a file that is usually a
          -- list but is sometimes a string -- check-ticket-verification-is-a-list.sh exists precisely
          -- because both occur. A bare string becomes a one-element array rather than being dropped.
          coalesce(CASE WHEN jsonb_typeof(p->'verification') = 'array'
               THEN ARRAY(SELECT jsonb_array_elements_text(p->'verification'))
               WHEN nullif(p->>'verification','') IS NOT NULL
               THEN ARRAY[p->>'verification']
               END, '{}'),
          nullif(p->>'verification_command',''),
          -- ⚠ AND IT MUST BE IN THE INSERT LIST TOO, NOT ONLY THE UPDATE ARM. My first draft added
          -- the merge to ON CONFLICT and stopped there; `extra` was absent from the column list, so
          -- `EXCLUDED.extra` was the column DEFAULT `{}` and the merge computed `existing || {}` —
          -- a no-op that returned `ok` on every call. Driven: the arm was live, the verdict was ok,
          -- and the key still never arrived. An UPDATE arm referring to EXCLUDED.<col> is inert
          -- unless <col> is in the INSERT.
          coalesce(p->'extra', '{}'::jsonb),
          -- ⚠ THE WHOLE OF THIS MIGRATION: record whether the PAYLOAD CARRIED THE KEY.
          -- `p ? 'claimed_by'` is already tested four times in this function and its answer was
          -- thrown away every time. absent and explicit-null are OPPOSITE INSTRUCTIONS and both
          -- arrive as `claimed_by IS NULL`, so no rule read off the row can tell them apart.
          (p ? 'claimed_by'),
          -- ⚠ THE SAME VALUE THE DRIFT INSERT AT THE FOOT OF THIS FUNCTION RECORDS, WRITTEN TO THE
          -- ROW THAT OWNS IT. `archived_from_status` has been on the wire since migration 83
          -- (ledger-db.sh `_archived_payload`) and had nowhere to land: ledger-db.sh:1220 said in
          -- so many words "`ledger.ticket` has NO archived_from_status column". Now it does.
          -- ⚠ THE VALUE LIST IS REPEATED HERE RATHER THAN TRUSTED TO THE CHECK CONSTRAINT. A
          -- payload carrying `archived_from_status: "archived"` (the coercion echoed back, which
          -- recovers nothing) or any other word must land as NULL, not raise -- this function is an
          -- OBSERVER and must never break the write it is mirroring.
          CASE WHEN coalesce(p->>'archived_from_status','') IN ('passing','wont_do')
               THEN p->>'archived_from_status' END,
          -- ⚠ MIGRATION 156. These three were REQUIREMENT fields with no column: they reached the
          -- row as unmodelled keys inside `extra`, which the arm below REPLACES wholesale whenever
          -- a writer read a COMPLETE ticket file. A file that lost one took the row's copy with it
          -- on the next sync, silently and with no drift row. Same argument migration 141 accepted
          -- for `legacy_source`: "`extra` is rewritten by every mirror; a column set once by the
          -- only function that can set it is not."
          nullif(p->>'evidence',''),
          -- ⚠ `acceptance` IS A LIST WHEREVER IT EXISTS — measured 260 arrays, 0 strings — so it is
          -- `text[]` like `verification`, not text. Flattening it would destroy the boundaries the
          -- way `notes` was flattened, which is its own outstanding defect.
          -- ⚠ BOTH SHAPES, LIKE `verification` — AND THE ARRAY-ONLY VERSION I WROTE FIRST WOULD
          -- HAVE SILENTLY DROPPED 137 OF THEM. I measured the shape in the ROWS (`extra->'acceptance'`
          -- : 260 arrays, 0 strings) and concluded "it is always a list". The SOURCES disagree:
          -- 41 per-ticket files hold a list, and the legacy jsonl holds 83 lists and **137 STRINGS**.
          -- A row-side shape census answers a question about what the IMPORT already normalised, not
          -- about what a writer can send. Caught by comparing against the files, which is the whole
          -- reason that comparison is the verification and not the row read.
          coalesce(CASE WHEN jsonb_typeof(p->'acceptance') = 'array'
               THEN ARRAY(SELECT jsonb_array_elements_text(p->'acceptance'))
               WHEN nullif(p->>'acceptance','') IS NOT NULL
               THEN ARRAY[p->>'acceptance']
               END, '{}'),
          -- ⚠ LEGACY, AND THE COLUMN PRESERVES RATHER THAN REVIVES. 1,106 of 1,246 stamps name a
          -- commit that is not on main (2026-08-18) — invalid there BY CONSTRUCTION, because every
          -- merge method rewrites the commit the stamp names. Nothing here backfills from git,
          -- re-stamps, or requires it.
          nullif(p->>'last_verified_commit',''))
  ON CONFLICT (id) DO UPDATE SET
    -- ⚠ TITLE IS A REQUIREMENT FIELD AND IT WAS THE ONLY ONE WRITTEN UNCONDITIONALLY. It shared a
    -- line with area and status, which are NOT requirement fields and stay git's (migration 30).
    -- Splitting it out is the whole change for this column.
    title = CASE WHEN v_row_exists THEN ledger.ticket.title ELSE EXCLUDED.title END,
    area = EXCLUDED.area, status = EXCLUDED.status,
    -- ⚠ COALESCE, SO AN ABSENT KEY PRESERVES. Only `_archived_payload` sends this key, so EVERY
    -- ordinary mirror of an archived ticket arrives without it -- an unconditional
    -- `= EXCLUDED.archived_from_status` would wipe the terminal outcome on the very next sync,
    -- which is the defect this column exists to end, rebuilt one layer down.
    --
    -- ⚠ AND IT OVERWRITES WHEN THE KEY IS PRESENT, WHICH IS A DELIBERATE DIVERGENCE FROM THE DRIFT
    -- ROW BELOW. That INSERT is guarded by NOT EXISTS and so is write-once; migration 83 named the
    -- consequence as a known limitation -- "if an archived ticket's terminal status were later
    -- CHANGED (passing -> wont_do) the recorded value would be stale" -- and could not do better,
    -- because a second row makes the reader's tie-break ambiguous and deleting the old one violates
    -- the append-only property that makes the log trustworthy. A COLUMN has neither problem: the
    -- correction is an UPDATE. The log keeps its original entry as history of what was recorded at
    -- archival time, and the row carries what is true now.
    archived_from_status = coalesce(EXCLUDED.archived_from_status, ledger.ticket.archived_from_status),
    -- ⚠ KEY-PRESENCE GUARDED, LIKE `priority` NINE LINES BELOW AND EVERY PROSE FIELD AFTER IT.
    -- (fix_the_mirror_wipes_a_claim_the_database_holds)
    -- This was `EXCLUDED.claimed_by` unconditionally, so EVERY sync from origin/main overwrote a
    -- claim the DATABASE holds -- and main does not know a claim until its lock branch MERGES,
    -- which is the whole duration of the work. The ticket then reappeared on v_frontier as free
    -- and an agent could be routed onto work somebody was already doing.
    --
    -- ⚠ THE THREE CASES ARE DISTINGUISHABLE, WHICH IS WHY KEY PRESENCE IS ENOUGH. Measured across
    -- the live corpus 2026-08-30 -- 129 / 82 / 3:
    --     key ABSENT        never claimed, or claimed only on a branch  -> PRESERVE the db value
    --     key PRESENT+NAME  the claim commit is merged to main          -> SET it
    --     key PRESENT+NULL  an explicit hand-back                       -> CLEAR it
    -- The tooling OMITS the key entirely for a never-claimed ticket, so "unclaimed" and
    -- "claimed but unmerged" are NOT the same payload. Keying on the VALUE would conflate them
    -- and is the defect this line is fixing.
    --
    -- ⚠ AND THE CLEAR PATH MUST SURVIVE: there is NO ledger.release, so the mirror is the ONLY
    -- route by which an unclaim can reach the database. A guard that simply stopped writing
    -- claimed_by would build a claim that can never be given back.
    -- ⚠ MIGRATION 104. 028's key test is KEPT as the outer condition -- an absent key still means
    -- "git did not mention ownership" and still preserves. What changes is the case 028 could not
    -- have anticipated: the key PRESENT and NULL, which was three deliberate hand-backs when it was
    -- written and is now all 251 live ticket files on main.
    claimed_by = CASE
      -- git NAMES a holder. Git can only know this positively, so take it. (Unchanged.)
      WHEN p ? 'claimed_by' AND EXCLUDED.claimed_by IS NOT NULL THEN EXCLUDED.claimed_by
      -- git says UNOWNED while the database holds an owner. `lock_held` is the only thing that
      -- separates main's ignorance from a real hand-back, and ONLY 'false' -- an explicit answer
      -- from a caller that actually asked git -- is allowed to clear.
      WHEN p ? 'claimed_by' AND EXCLUDED.claimed_by IS NULL
           AND ledger.ticket.claimed_by IS NOT NULL
           AND coalesce(nullif(p->>'lock_held',''), 'unknown') <> 'false'
        THEN ledger.ticket.claimed_by
      -- an explicit lock_held='false', or no owner held: 028's behaviour, unchanged. This is the
      -- arm #7782's departed-agent clear travels through and it must keep working.
      WHEN p ? 'claimed_by' THEN EXCLUDED.claimed_by
      ELSE ledger.ticket.claimed_by END,
    claimed_at = COALESCE(ledger.ticket.claimed_at, EXCLUDED.claimed_at),
    -- ⚠ THREE ARMS, AND THE MIDDLE ONE IS MIGRATION 135. A payload that carried the key records
    -- true. A payload that is a COMPLETE FILE and did not carry it records FALSE — that is positive
    -- evidence about the file, not an absence. Anything else preserves.
    --
    -- ⚠⚠ WHY THE MIDDLE ARM HAD TO EXIST AT ALL: WITHOUT IT THE FLAG COULD NEVER BECOME FALSE FOR
    -- ANY ROW THAT ALREADY EXISTED. 129 wrote false only from the INSERT arm, and every row in this
    -- table was already inserted — measured before this migration, ZERO of 2805 rows carried false,
    -- and 391 carried a NAME with a NULL flag. 129's PR body said "a sync populates it from the
    -- files that still exist"; it could not, because a sync UPDATEs. The prose was right about the
    -- 171 live files that DO carry the key and wrong about the archived ones that do not.
    --
    -- ⚠ `extra_complete` IS THE RIGHT SIGNAL AND IT IS NOT NEW HERE. `LEDGER_TICKET_PAYLOAD_JQ`
    -- appends it when the writer read a WHOLE ticket file, and migrations 128/129 already trust it
    -- for the `extra` arm below to decide REPLACE-vs-MERGE. It is exactly the distinction this
    -- function's own comment says `p ? '<col>'` is about: payload COMPLETENESS. A partial ownership
    -- payload (claim/park/release) carries no such flag and still preserves, which is what stops a
    -- claim wiping the answer.
    --
    -- ⚠ FALSE IS NOT "NO OWNER". The `claimed_by` arm above is untouched and still decides the
    -- VALUE; this records only whether git's file MENTIONED the key, so a row can hold a name and a
    -- false flag at once — that is the 11-ADDS population, and it is what reconstruction reads to
    -- stop inventing a `claimed_by` the file does not carry.
    -- (infra_the_mirror_never_records_whether_claimed_by_was_absent_or_null)
    claimed_by_carried = CASE
                           WHEN p ? 'claimed_by' THEN true
                           WHEN coalesce((p->>'extra_complete')::boolean, false) THEN false
                           ELSE ledger.ticket.claimed_by_carried END,
    -- ⚠⚠ ONE GUARD FOR ALL FOUR PARK COLUMNS, KEYED ON THE STATUS GIT JUST WROTE.
    -- (infra_a_park_reason_outlives_its_park_because_three_columns_use_two_guards)
    --
    -- WHAT WAS HERE: parked_reason and parked_by tested KEY PRESENCE (`p ? 'parked_reason'`, absent
    -- key = PRESERVE) while parked_at tested VALUE NULLNESS (`EXCLUDED.parked_reason IS NULL`,
    -- absent key = ERASE). ledger-db.sh omits the key for every file with no `parked` key -- i.e.
    -- every unparked and every archived ticket -- so ONE payload drove the two guards in OPPOSITE
    -- directions: the date erased, the reason and owner kept for ever.
    --
    -- ⚠ THE OLD COMMENT ASSERTED THEY "wipe in sympathy -- ONE failure presenting as two". Sympathy
    -- is what they would do IF THEY SHARED A GUARD. They did not. So checking the code against its
    -- own comment found AGREEMENT, which is why this survived review. Measured: 21 rows carried a
    -- park reason while not parked; 12 of them had no date.
    --
    -- ⚠ AND park_kind WAS NEVER TOUCHED HERE AT ALL, which is why 26 rows carried a stale kind --
    -- the very fact that made four independent readers rule `park_kind` out as a way to ask "is
    -- this parked?". Fixing the cause beats continuing to route around it.
    --
    -- ⚠⚠ THIS RETIRES MIGRATION 29'S PROTECTION, DELIBERATELY, AND HERE IS WHY -- so that a reader
    -- who meets 29's careful argument does not restore it. 29 guarded on key presence so that a
    -- park held ONLY in the database (written by `ledger.park`, which touches no file) would
    -- survive a sync from main that knew nothing about it. Three reasons it goes:
    --   · MEASURED 2026-09-02: of 67 parked rows, main's file says `status: parked` for 66 and
    --     DIFFERS for ZERO. The single row with no file at all is `zz_probe_don`, a test probe --
    --     the same population migration 60 excludes from the board views. The guard was defending
    --     an empty set while damaging the live one.
    --   · The cutover makes the DATABASE authoritative and git a derived output, at which point git
    --     stops being a writer that could be ignorant of a database-held park. 29 protects against
    --     a direction of travel we are reversing.
    --   · One fact guarded three ways with two of them disagreeing is the defect, independently of
    --     which guard wins.
    -- ⚠ A DETECTOR SHIPS WITH THIS (scripts/check-no-db-only-park.sh) and FAILS if that population
    -- ever stops being empty. Retiring a guard because its population is empty, with nothing
    -- watching it fill, is how `v_agent_demonstrated` came to count an event never once written.
    --
    -- ⚠ THE CLEAR PATH STILL WORKS IN ONE STEP: `unpark` flips status out of 'parked' in the same
    -- statement, so all four columns clear together. Do not "restore" a key-presence branch here to
    -- make a DB-only park survive -- that reintroduces exactly the split this removes.
    -- ⚠⚠ NO KEY-PRESENCE BRANCH HERE, AND ITS ABSENCE IS DELIBERATE — I WROTE ONE AND IT WAS DEAD.
    -- My first version was `CASE WHEN p ? 'parked_reason' THEN EXCLUDED.parked_reason ELSE
    -- ledger.ticket.parked_reason END`, to preserve a database-held reason when the payload omitted
    -- the key. That branch CANNOT BE REACHED through this function.
    -- ⚠ PostgreSQL evaluates CHECK constraints on the PROPOSED INSERT TUPLE, before the conflict is
    -- resolved — not on the row the ON CONFLICT UPDATE would produce. Driven on a temp table:
    --     INSERT (1,'parked',NULL) ON CONFLICT DO UPDATE SET r = COALESCE(EXCLUDED.r, t.r)
    --       -> ERROR: violates check constraint "needs_r"
    --          DETAIL: Failing row contains (1, parked, null)   <- the PROPOSED row
    -- So a payload asserting status='parked' with no reason is refused by parked_needs_a_reason
    -- (migration 51) and the preserve branch never runs. Keeping it would be a guard that reads as
    -- protection and is a hole — the exact shape this file's own history is made of.
    -- ⚠ THE CONTRACT THAT REPLACES IT IS BETTER AND IS ENFORCED, NOT ASSUMED: if a payload says a
    -- ticket is parked, it must say WHY, or the mirror refuses the row loudly and records the
    -- refusal. The mirror therefore cannot create a reasonless park at all.
    parked_reason = CASE WHEN EXCLUDED.status = 'parked' THEN EXCLUDED.parked_reason ELSE NULL END,
    -- No invented date. If git says parked and neither the payload nor the row carries a date, the
    -- constraint refuses the row and the mirror records a refusal -- which is the honest signal for
    -- a file that claims a park while describing none.
    parked_at = CASE WHEN EXCLUDED.status = 'parked'
                     THEN COALESCE(ledger.ticket.parked_at, EXCLUDED.parked_at)
                     ELSE NULL END,
    -- Same reasoning: EXCLUDED.parked_by derives from parked_reason in the INSERT list, and a
    -- payload that says 'parked' is guaranteed to carry a reason or be refused, so it is non-null
    -- exactly when it is needed. A key-presence branch here would be dead for the same reason.
    parked_by = CASE WHEN EXCLUDED.status = 'parked' THEN EXCLUDED.parked_by ELSE NULL END,
    -- park_kind is not in the INSERT list, so it is only ever preserved or cleared here. It is set
    -- by ledger.park and ledger.reclassify_park, which are the verbs that own it.
    park_kind = CASE WHEN EXCLUDED.status = 'parked' THEN ledger.ticket.park_kind ELSE NULL END,
    -- ⚠ RESTORED BY 187 — 080 put this here and 093 silently dropped it when it rebuilt this function
    -- from a stale definition; 160 inherited the loss. park_summary is DB-owned (ledger.park writes
    -- it), so it FOLLOWS park_kind: the file's ask when the file has one, the row's otherwise, NULL off
    -- a park. See 080 for why COALESCE and not EXCLUDED, and why the payload's `has()` guard matters.
    park_summary = CASE WHEN EXCLUDED.status = 'parked'
                        THEN COALESCE(EXCLUDED.park_summary, ledger.ticket.park_summary)
                        ELSE NULL END,
    verified_by_pr = COALESCE(EXCLUDED.verified_by_pr, ledger.ticket.verified_by_pr),
    issue = COALESCE(EXCLUDED.issue, ledger.ticket.issue),
    -- ⚠ ONLY WHEN THE PAYLOAD ACTUALLY CARRIES THE KEY. `p ? 'priority'` distinguishes "the file
    -- says medium" from "this caller did not send a priority at all" -- and they are different
    -- facts. Keying on the VALUE instead would let any older caller silently reset every ticket to
    -- the default, which is the failure this whole migration exists to undo, reintroduced from the
    -- other direction.
    priority = CASE WHEN p ? 'priority' THEN EXCLUDED.priority ELSE ledger.ticket.priority END,
    -- ⚠ SAME KEY-PRESENCE RULE FOR EVERY ONE OF THESE, and it is not decoration: `mirror` is called
    -- by feature-ticket.sh with a payload built for OWNERSHIP, which carries none of these fields.
    -- Keying on the value would make every claim, park and release WIPE the requirement it does not
    -- mention -- turning a fix that carries more data into one that destroys it.
    depends_on            = CASE WHEN p ? 'depends_on'            THEN EXCLUDED.depends_on            ELSE ledger.ticket.depends_on END,
    solo                  = CASE WHEN p ? 'solo'                  THEN EXCLUDED.solo                  ELSE ledger.ticket.solo END,
    parent                = CASE WHEN p ? 'parent'                THEN EXCLUDED.parent                ELSE ledger.ticket.parent END,
    raised_by             = CASE WHEN p ? 'raised_by'             THEN EXCLUDED.raised_by             ELSE ledger.ticket.raised_by END,
    -- ⚠ MIGRATION 140'S RULE, APPLIED TO THE THREE FIELDS THAT JOINED THE TABLE AFTER IT. The
    -- DATABASE is authoritative for the requirement, so a file's value is NOT applied to an
    -- existing row; the disagreement is RECORDED as drift instead (see v_drifted above). Writing
    -- them from the payload would reopen exactly the defect 140 closed, one field wider.
    -- ⚠ FILL-IF-EMPTY, NEVER OVERWRITE (migration 160). These three read
    -- `= ledger.ticket.<col>` — insert-only — and the sentence above claimed the file's value was
    -- recorded as drift instead. It was not: the drift detector knew five field names and none of
    -- them was these. So a value authored AFTER the row existed was neither applied nor recorded,
    -- and that is the whole normal lifecycle: `raise` creates the row, the agent writes the
    -- evidence when the work is FINISHED. Driven 2026-09-17 — 4 of 1,987 files carrying evidence
    -- had NULL in the row, and the fourth was raised and finished that same day.
    -- ⚠ 140 IS NOT REOPENED, AND THE DISTINCTION IS THE WHOLE FIX: a row that HOLDS a value keeps
    -- it, always. NULL is not an opinion the database is defending. `coalesce` says exactly that
    -- and nothing more.
    evidence              = coalesce(ledger.ticket.evidence, nullif(EXCLUDED.evidence,'')),
    -- ⚠ EMPTY ARRAY, NOT NULL, IS THE NO-OPINION STATE HERE — the column is NOT NULL DEFAULT '{}'
    -- (migration 156), so `coalesce` would never fire and this would stay insert-only in disguise.
    acceptance            = CASE WHEN coalesce(array_length(ledger.ticket.acceptance,1),0) = 0
                                 THEN EXCLUDED.acceptance ELSE ledger.ticket.acceptance END,
    last_verified_commit  = coalesce(ledger.ticket.last_verified_commit, nullif(EXCLUDED.last_verified_commit,'')),
    notes                 = ledger.ticket.notes,
    user_visible_behavior = ledger.ticket.user_visible_behavior,
    verification          = ledger.ticket.verification,
    verification_command  = ledger.ticket.verification_command,
    -- ⚠ `extra` WAS NEVER WRITTEN BY THIS FUNCTION, SO EVERY UNMODELLED KEY WAS FROZEN AT IMPORT.
    -- grep the pre-27 definition for "extra" and there are ZERO matches: the column was populated
    -- once by the import migration and never again. A key added to a ticket file afterwards never
    -- arrived; a key edited afterwards never updated. Measured on demand: mirroring a payload
    -- carrying `probe_key` returned `ok` and the row still answered `extra ? 'probe_key'` = false.
    --
    -- ⚠ IT WAS HARMLESS ONLY WHILE GIT IS AUTHORITATIVE, because nothing reads `extra` to decide
    -- anything. It stops being harmless the moment a ticket FILE is generated from this row —
    -- CUTOVER.md step 5 — because the generated file would silently drop whatever prose arrived
    -- after the import. This is the precondition for that step, not a tidy-up.
    --
    -- ⚠ MERGE, DO NOT REPLACE, AND GUARD ON KEY PRESENCE. `||` is a shallow merge so a payload that
    -- carries `extra` updates the keys it names and leaves the others; a payload that OMITS it
    -- changes nothing at all, exactly like the prose fields above. Replacing outright would let the
    -- 13-field `_emit` path — which carries no prose and no extra — blank a ticket's whole tail on
    -- every incremental run, which is the failure this repo has now paid for twice in this table.
    -- ⚠ THREE STATES, NOT TWO. A payload can now say WHICH it is, and the third state is the one
    -- this whole change exists for:
    --   `extra_complete` true   the writer read the WHOLE ticket file, so EXCLUDED.extra is the
    --                           complete set of unmodelled keys -> REPLACE, and a key the file has
    --                           DROPPED disappears. The withdrawal is recorded.
    --   `extra` present, no flag  a partial writer -> MERGE, exactly as before this migration.
    --   `extra` absent            says nothing about extra -> KEEP, exactly as before.
    --
    -- ⚠ THE MERGE COULD NOT EXPRESS A WITHDRAWAL, AND THAT WAS THE DEFECT. `existing || excluded`
    -- can add a key and change a value but can never remove one, so a key recorded once outlived
    -- every later read of the file. `check-ledger-reproduces-the-ticket-files.sh` then reported it
    -- as a key the reconstruction "invents": 110 lock_intent, 55 park_summary, 38 issue, 11
    -- claimed_by, 8 acceptance_criteria, 7 park_kind. Measured 2026-09-08: 655 rows carry
    -- lock_intent in extra, 544 files still carry it, 111 do not.
    -- (fix_the_ledger_reconstruction_invents_values_and_an_invented_key_is_indistinguishable_from_a_fact)
    --
    -- ⚠ WHY THE FLAG RATHER THAN JUST REPLACING WHENEVER `p ? 'extra'`. Today every writer builds
    -- extra with LEDGER_TICKET_PAYLOAD_JQ over a COMPLETE file -- driven: all three `_emit` call
    -- sites pass `git show <ref>:<path>` or `cat <file>`, and `mirror` passes the file itself -- so
    -- an unconditional replace would be correct RIGHT NOW. It would also be a landmine: the moment
    -- someone adds a writer that projects a subset, an unconditional replace blanks the tail of
    -- every ticket it touches. That failure has been paid for twice in this table already. A writer
    -- that forgets the flag degrades to the OLD, SAFE behaviour instead.
    --
    -- ⚠ THE COMMENT THIS REPLACES JUSTIFIED THE MERGE WITH "the 13-field `_emit` path — which
    -- carries no prose and no extra". That `_emit` no longer exists; it was fixed and now shares the
    -- full payload builder. The justification outlived the thing it described, which is why the
    -- merge went on removing nothing long after it needed to.
    extra = CASE
              WHEN p ? 'extra' AND coalesce((p->>'extra_complete')::boolean, false)
                   THEN coalesce(EXCLUDED.extra,'{}'::jsonb)
              WHEN p ? 'extra'
                   THEN coalesce(ledger.ticket.extra,'{}'::jsonb) || coalesce(EXCLUDED.extra,'{}'::jsonb)
              ELSE ledger.ticket.extra END,
    updated_at = now()
  RETURNING updated_at INTO v_after_updated;

  -- ⚠ THE EVENT LOG IS THE PRODUCT. A mirrored write is recorded as 'mirrored' and never as the
  -- verb it copied — an agent's `claim` event must mean "an agent claimed it here", or
  -- v_agent_demonstrated starts counting file copies as delivered work.
  -- ⚠ ONLY WHEN SOMETHING ACTUALLY CHANGED. (migration 108) The sync re-mirrors every ticket it is
  -- given whether or not its file moved, so an unconditional insert here recorded one row per
  -- ticket per pass: 278,523 of 278,974 events, 16,649 of them in the 24h before this was written.
  -- The trigger installed by 108 puts `updated_at` back when the proposed row differs in nothing
  -- else, so an unchanged `updated_at` IS the verdict "nothing changed" -- asked once, in one place.
  -- ⚠ NAMED LIMITATION: two mirrors of the SAME ticket inside ONE transaction share `now()`, so a
  -- second one that does change the row can leave `updated_at` at the value the first one wrote and
  -- go unlogged. Neither caller does that -- `sync` and `feature-ticket.sh mirror` both mirror an id
  -- once per statement -- and the ROW is correct either way; only the event would be missed.
  IF v_before_updated IS NULL OR v_after_updated IS DISTINCT FROM v_before_updated THEN
    INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
    VALUES (v_id, 'mirrored', session_user::text,
            jsonb_build_object('status', v_status, 'claimed_by', v_owner));
  END IF;
  -- ⚠ CLEAR THE MARK ON SUCCESS, or a row that was ever refused is excluded for ever and the
  -- frontier shrinks silently — the same defect pointing the other way.
  UPDATE ledger.ticket SET mirror_refused_at = NULL, mirror_refused_reason = NULL
   WHERE id = v_id AND mirror_refused_at IS NOT NULL;

  -- ⚠⚠ RECORD WHAT THE ARCHIVE COERCION DESTROYS. THIS IS THE WHOLE MIGRATION.
  -- `scripts/ledger-db.sh` coerces an archived ticket's status to 'archived' before the payload
  -- gets here, and until now it OVERWROTE the file's real terminal status, so the database could
  -- not reproduce it. MEASURED 2026-09-02: 2241 of 2241 archived tickets (2194 passing, 46
  -- wont_do) — and those files are what CUTOVER step 7 deletes, so the delivered-vs-abandoned
  -- distinction was one deletion away from being gone permanently and silently.
  --
  -- ⚠ THE COERCION IS CORRECT AND IS NOT TOUCHED. `status = 'archived'` is load-bearing in SEVEN
  -- places — export's corpus filter (the only thing stopping `export --write` overwriting ~2,194
  -- real files), the readiness count, `finished:archived` in 03-protect, dependency satisfaction,
  -- v_frontier's depends_on check, live_tickets per area, and the release guard in 39. "Preserve
  -- the terminal status" must NOT be read as "stop coercing": that would make archived parents
  -- stop satisfying depends_on, so the frontier would start HIDING ready tickets.
  -- ⚠ READ THE GATE, NOT THE PROSE. check-ledger-preserves-archived-terminal-status.sh keeps
  -- `where t.status = 'archived'` and joins import_drift on `field = 'status'`, returning
  -- `recoverable` when `found` is passing or wont_do. It asks for a RECORD of the coercion, which
  -- is exactly what `area` already does. Three documents say "preserve the status"; the gate says
  -- "record what you coerced", and only one of those is safe.
  -- ⚠ THE DEFECT WAS THE LAYER. Coercing in bash meant this function never saw the real value and
  -- so could never log drift for it — which is why no status drift row has ever existed.
  --
  -- ⚠ THE GUARD IS NOT AN OPTIMISATION. `import_drift` is APPEND-ONLY and the mirror re-runs over
  -- every ticket, so an unguarded INSERT would add ~2,241 rows on every sync, for ever.
  -- ⚠ KNOWN LIMITATION, NAMED RATHER THAN HIDDEN: at most one terminal row is ever written per
  -- ticket, so if an archived ticket's terminal status were later CHANGED (passing -> wont_do) the
  -- recorded value would be stale. That is deliberate. The alternative — inserting a second row —
  -- makes the gate's `max(d.found)` ambiguous (it would return 'wont_do' whichever way the change
  -- went, since 'p' < 'w'), and DELETING the old row would violate the append-only property that
  -- makes this log trustworthy. Archiving is terminal, so the case is rare; a stale row here is
  -- visible and correctable, an ambiguous max() is not.
  IF p ? 'archived_from_status'
     AND coalesce(p->>'archived_from_status','') IN ('passing','wont_do')
     -- ⚠ ALIASED AND FULLY QUALIFIED, AND `d.found` IS THE REASON. `FOUND` IS A BUILT-IN PLPGSQL
     -- VARIABLE, so an unqualified `found` here is `column reference "found" is ambiguous`
     -- (SQLSTATE 42702) — and because plpgsql plans this whole IF condition as ONE statement, the
     -- short circuit does not save you: it failed on EVERY mirror call, including live tickets that
     -- never reach this clause. Caught by the positive control asserting the ROW; the control's
     -- first assertion (the clause is present in pg_proc) passed happily while nothing worked.
     AND NOT EXISTS (SELECT 1 FROM ledger.import_drift d
                      WHERE d.entity = 'ticket' AND d.id = v_id AND d.field = 'status'
                        AND d.found IN ('passing','wont_do'))
  THEN
    INSERT INTO ledger.import_drift(entity,id,field,found,note)
    VALUES ('ticket', v_id, 'status', p->>'archived_from_status',
            'archived: ledger.ticket.status must stay ''archived'' for seven consumers, so this row is the only copy of the terminal status');
  END IF;
  -- ⚠ THE CANNOT-TELL IS RECORDED, NOT SWALLOWED. The ticket's bar is that a reader gets the holder
  -- or an explicit cannot-tell, never a confident wrong "unowned". Keeping the owner delivers the
  -- first; this row is what makes the second READABLE from outside the function.
  -- ⚠ ONLY WHEN THE CALLER DID NOT SAY. `lock_held='true'` is a complete answer -- main is known to
  -- be ignorant and keeping the owner is CORRECT, not uncertain -- so it records nothing. Without
  -- that narrowing every hourly sync would write ~94 rows and the table would be noise.
  IF v_held_owner IS NOT NULL
     AND (p ? 'claimed_by') AND nullif(p->>'claimed_by','') IS NULL
     AND v_lock IS NULL THEN
    INSERT INTO ledger.import_drift(entity,id,field,found,note)
    VALUES ('ticket', v_id, 'claimed_by', v_held_owner,
            'payload says unowned and the caller did not report whether a lock branch exists — CANNOT TELL, owner kept (migration 104)');
  END IF;

  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  -- ⚠ THE MIRROR MUST NEVER BREAK THE WRITE IT IS MIRRORING. Git is authoritative during the
  -- migration; this is an observer. Found by driving it: a ticket whose title failed
  -- `ticket_title_check` made the whole call RAISE, and every other refusal in this function
  -- returns a verdict string. Wired into feature-ticket.sh, a throw here would have failed an
  -- agent's claim because the SHADOW copy disagreed — the observer breaking the observed, which is
  -- the same severity class as a readiness probe that gates the repair it is wrong about.
  --
  -- ⚠ AND IT MUST NOT SWALLOW THE REASON EITHER. A silent best-effort mirror drifts invisibly,
  -- which is the whole defect this database exists to end. The verdict carries SQLSTATE and the
  -- message so the caller can print it, and the row is recorded as drift in its own transaction —
  -- the failing INSERT rolled back the drift row that explained it, so it needs a subtransaction.
  DECLARE v_msg text := SQLERRM; v_state text := SQLSTATE;
  BEGIN
    BEGIN
      INSERT INTO ledger.import_drift(entity,id,field,found,note)
      VALUES ('ticket', v_id, 'mirror_refused', left(v_state,20), left(v_msg,300));
    EXCEPTION WHEN OTHERS THEN NULL;  -- never let the audit write mask the original failure
    END;
    PERFORM ledger._mark_refused(v_id, 'refused:' || v_state);
    RETURN 'refused:' || v_state || ':' || left(v_msg, 120);
  END;
END $$;


--
-- Name: FUNCTION mirror_ticket(p jsonb); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.mirror_ticket(p jsonb) IS 'Mirror one ticket from its file into the row. A payload declaring source <> ''main'' may create a row and may not update one (159). The requirement fields are not overwritten on an existing row (140); the three that joined after it are FILLED when the row holds nothing and RECORDED as drift when it does (160) — before which they were neither, under a comment saying they were recorded. park_summary is written again (187; 093 had dropped 080''s arm).';


--
-- Name: normalise_shaped_extra_keys(jsonb); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.normalise_shaped_extra_keys(e jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE
  v jsonb := coalesce(e, '{}'::jsonb);
BEGIN
  -- A non-object `extra` is not this function's business; the column's own shape is settled
  -- elsewhere and inventing an object here would hide that.
  IF jsonb_typeof(v) IS DISTINCT FROM 'object' THEN RETURN v; END IF;

  -- evidence: array -> newline-joined string; JSON null -> key dropped. (087's transform, verbatim.)
  -- ⚠ THE `coalesce(..., '')` IS NOT DECORATION. `string_agg` over an EMPTY array returns SQL NULL,
  -- and `jsonb_set(target, path, NULL)` returns NULL for the WHOLE DOCUMENT — so an `"evidence": []`
  -- would have blanked every other key in `extra` and returned a verdict of `ok`. Driven.
  IF jsonb_typeof(v->'evidence') = 'array' THEN
    v := jsonb_set(v, '{evidence}',
           to_jsonb(coalesce((SELECT string_agg(value #>> '{}', E'\n')
                                FROM jsonb_array_elements(v->'evidence') AS value), '')));
  ELSIF jsonb_typeof(v->'evidence') = 'null' THEN
    v := v - 'evidence';
  END IF;

  -- scope: string -> one-element array; JSON null -> key dropped.
  IF jsonb_typeof(v->'scope') = 'string' THEN
    v := jsonb_set(v, '{scope}', jsonb_build_array(v->>'scope'));
  ELSIF jsonb_typeof(v->'scope') = 'null' THEN
    v := v - 'scope';
  END IF;

  -- acceptance: string -> one-element array; JSON null -> key dropped.
  IF jsonb_typeof(v->'acceptance') = 'string' THEN
    v := jsonb_set(v, '{acceptance}', jsonb_build_array(v->>'acceptance'));
  ELSIF jsonb_typeof(v->'acceptance') = 'null' THEN
    v := v - 'acceptance';
  END IF;

  RETURN v;
END $$;


--
-- Name: FUNCTION normalise_shaped_extra_keys(e jsonb); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.normalise_shaped_extra_keys(e jsonb) IS 'Coerces the three shape-constrained `extra` keys to the shapes migration 087 fixed: evidence -> string (array joined on newlines), scope and acceptance -> array (a bare string wrapped). A JSON null is dropped. Every other shape is left alone so the CHECK constraints still refuse it.';


--
-- Name: normalise_shaped_extra_keys_trg(); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.normalise_shaped_extra_keys_trg() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
BEGIN
  NEW.extra := ledger.normalise_shaped_extra_keys(NEW.extra);
  RETURN NEW;
END $$;


--
-- Name: owner_set_field(text, text, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.owner_set_field(p_id text, p_field text, p_value text, p_actor text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE v_actor text; v_arr text[];
BEGIN
  v_actor := NULLIF(btrim(coalesce(p_actor,'')),'');
  IF v_actor IS NULL THEN RETURN 'refused:no-actor'; END IF;
  IF NOT EXISTS (SELECT 1 FROM ledger.ticket WHERE id = p_id) THEN RETURN 'refused:no-such-ticket'; END IF;

  -- ⚠ EVERY REFUSAL IS A NAMED STRING, NEVER AN EXCEPTION AND NEVER A SILENT NO-OP. The phase-5
  -- ticket's negative control is "attempt a change the procedure must refuse and confirm the SCREEN
  -- reports the refusal rather than appearing to succeed". A button that cannot fail visibly is the
  -- corruption risk phase 5 was deferred to avoid, so the refusal has to survive the trip back.
  CASE p_field
    WHEN 'priority' THEN
      IF ledger.priority_of_strict(p_value) IS NULL THEN RETURN 'refused:priority-not-recognised'; END IF;
      p_value := ledger.priority_of_strict(p_value)::text;
    WHEN 'area' THEN
      IF NOT EXISTS (SELECT 1 FROM ledger.area WHERE name = p_value) THEN RETURN 'refused:area-not-on-the-list'; END IF;
    WHEN 'status' THEN
      -- ⚠ THE GROOMING STATUSES ONLY. in_progress, passing and archived are EARNED, through claim /
      -- flip_passing / archive, each of which enforces rules this procedure does not have -- deps,
      -- solo, holder, a verifying PR. Letting the owner type `passing` on a screen would route
      -- around every one of them, which is precisely what phase 5 was sequenced last to avoid.
      IF p_value NOT IN ('not_started','selected','blocked','wont_do') THEN
        RETURN 'refused:status-is-earned-not-set';
      END IF;
    WHEN 'title' THEN
      IF length(p_value) < 8 OR length(p_value) > 600 THEN RETURN 'refused:title-length'; END IF;

    -- ── the requirement fields, added by migration 136 ──────────────────────────────────────────
    -- ⚠ NOT NULL IN THE TABLE, AND `owner_override.value` IS NOT NULL TOO, SO A NULL BODY IS
    -- NORMALISED TO '' RATHER THAN REFUSED. Clearing a description is a legitimate edit; refusing it
    -- would leave the owner unable to undo his own typo except by retyping the original.
    WHEN 'user_visible_behavior' THEN p_value := coalesce(p_value,'');
    WHEN 'notes'                 THEN p_value := coalesce(p_value,'');
    WHEN 'verification_command'  THEN p_value := coalesce(p_value,'');
    WHEN 'verification' THEN
      -- ⚠⚠ REFUSED IF IT IS NOT A LIST -- NOT COERCED INTO A ONE-ELEMENT ONE. `mirror_ticket` DOES
      -- coerce a bare string that way, and that coercion is why `check-ticket-verification-is-a-list.sh`
      -- cannot be retired by the schema's own invariant: something normalises bad input into the
      -- valid type on the way in, so the column being text[] proves nothing about what git holds.
      -- `raise_ticket` already refuses (`verification-not-a-list`) and this follows it. **A
      -- constraint that can only be satisfied by discarding the input is not enforcing an invariant,
      -- it is laundering one.**
      BEGIN
        IF p_value IS NULL OR btrim(p_value) = '' THEN
          v_arr := ARRAY[]::text[];
        ELSIF jsonb_typeof(p_value::jsonb) <> 'array' THEN
          RETURN 'refused:verification-not-a-list:'||jsonb_typeof(p_value::jsonb);
        ELSE
          v_arr := ARRAY(SELECT jsonb_array_elements_text(p_value::jsonb));
        END IF;
      EXCEPTION WHEN OTHERS THEN
        RETURN 'refused:verification-not-json';
      END;
      -- STORED as PostgreSQL's own array literal so the trigger's `NEW.verification::text`
      -- comparison can ever match. See the trigger's header.
      p_value := v_arr::text;
    ELSE RETURN 'refused:field-not-owner-settable';
  END CASE;

  INSERT INTO ledger.owner_override(ticket_id, field, value, set_by)
       VALUES (p_id, p_field, p_value, v_actor)
  ON CONFLICT (ticket_id, field) DO UPDATE SET value = EXCLUDED.value, set_by = EXCLUDED.set_by, set_at = now();

  -- ⚠ THE UPDATE DELIBERATELY SETS NO FIELD -- THE TRIGGER APPLIES IT, AND THIS IS LOAD-BEARING.
  -- If this procedure wrote the value directly, the trigger would see incoming = override on its own
  -- write and immediately retire the override it had just created, so the very next mirror would
  -- undo the owner's change. Touching `updated_at` alone means the only writer that ever supplies a
  -- field VALUE is the mirror, which is what makes "incoming matches" unambiguously mean GIT CAUGHT
  -- UP rather than "we just wrote it ourselves".
  UPDATE ledger.ticket SET updated_at = now() WHERE id = p_id;

  INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
       VALUES (p_id, 'owner_set', v_actor, jsonb_build_object('field', p_field, 'value', left(p_value, 500)));
  RETURN 'ok';
END $$;


--
-- Name: FUNCTION owner_set_field(p_id text, p_field text, p_value text, p_actor text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.owner_set_field(p_id text, p_field text, p_value text, p_actor text) IS 'The sanctioned way to make a database value out-rank git for status/title/area/priority. Owner-only by GRANT (ledger_console). Agents may SELECT ledger.owner_override but not write it — an agent wanting a status to survive a sync is asking for the owner''s capability. See migration 30.';


--
-- Name: park(text, text, ledger.park_kind); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.park(p_id text, p_reason text, p_kind ledger.park_kind DEFAULT NULL::ledger.park_kind) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE t ledger.ticket%ROWTYPE; me text := session_user; v_kind ledger.park_kind;
BEGIN
  IF nullif(btrim(coalesce(p_reason,'')),'') IS NULL THEN RETURN 'need-reason'; END IF;
  SELECT * INTO t FROM ledger.ticket WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'no-such-ticket'; END IF;
  IF t.claimed_by IS DISTINCT FROM me THEN RETURN 'not-yours:'||coalesce(t.claimed_by,'(unclaimed)'); END IF;
  -- Carry a kind already on the row forward, so a re-run needs no argument. Refuse only when the
  -- kind is unknown to BOTH the caller and the row — which is a first park that did not say.
  v_kind := coalesce(p_kind, t.park_kind);
  IF v_kind IS NULL THEN RETURN 'need-kind'; END IF;
  UPDATE ledger.ticket
     SET status='parked', parked_reason=p_reason,
         -- ⚠ THE ORIGINAL PARK DATE SURVIVES A RE-PARK. This was `parked_at=now()` unconditionally,
         -- so calling park again to update a reason -- or, before ledger.reclassify_park existed,
         -- to change a KIND -- silently restamped it. On 2026-09-02 that cost eleven tickets their
         -- real park dates in a single sweep; they were recovered only because their owner happened
         -- to hold a pre-change snapshot. "When was this parked" is the field readers reason about,
         -- and a re-park does not change the answer. A genuinely new park still gets now().
         parked_at = CASE WHEN t.status = 'parked' THEN t.parked_at ELSE now() END,
         parked_by=me,
         park_kind=v_kind, updated_at=now()
   WHERE id=p_id;
  INSERT INTO ledger.ticket_event(ticket_id,verb,actor,detail)
    VALUES (p_id,'park',me,jsonb_build_object('reason',p_reason,'kind',v_kind));
  RETURN 'ok';
END $$;


--
-- Name: FUNCTION park(p_id text, p_reason text, p_kind ledger.park_kind); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.park(p_id text, p_reason text, p_kind ledger.park_kind) IS 'LEGACY SHIM. Delegates to the 4-argument park with no summary, so a first park is refused with `summary-empty` and a re-park carries the row''s existing summary forward. Kept rather than dropped so a checkout that has not pulled yet gets a verdict it can print instead of a missing-function error. See migration 62.';


--
-- Name: park(text, text, ledger.park_kind, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.park(p_id text, p_reason text, p_kind ledger.park_kind, p_summary text) RETURNS text
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
  SELECT ledger.park(p_id, p_reason, p_kind, p_summary, NULL::text)
$$;


--
-- Name: FUNCTION park(p_id text, p_reason text, p_kind ledger.park_kind, p_summary text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.park(p_id text, p_reason text, p_kind ledger.park_kind, p_summary text) IS 'LEGACY SHIM. Delegates to the five-argument park with no condition, so a first park is refused with `condition-need-condition` and a re-park carries the row''s existing condition forward. Kept rather than dropped so a checkout that has not pulled yet gets a verdict it can print instead of a missing-function error. ⚠ DECLARES NO PARAMETER DEFAULTS, and must not: defaults here make it callable at arities 2 and 3, where it collides with the three-argument legacy form. That is migration 65''s outage and migration 101 reintroduced it. See migration 103.';


--
-- Name: park(text, text, ledger.park_kind, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.park(p_id text, p_reason text, p_kind ledger.park_kind, p_summary text, p_condition text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE t ledger.ticket%ROWTYPE; me text := session_user; v_kind ledger.park_kind;
        v_sum text; v_cond text; v_verdict text; v_as_po boolean; v_same_park boolean;
BEGIN
  IF nullif(btrim(coalesce(p_reason,'')),'') IS NULL THEN RETURN 'need-reason'; END IF;
  SELECT * INTO t FROM ledger.ticket WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'no-such-ticket'; END IF;

  v_as_po := ledger.park_is_adjudicated_to_the_product_owner(t.status, t.claimed_by, t.adjudicated_from, me);
  IF t.claimed_by IS DISTINCT FROM me AND NOT v_as_po THEN
    RETURN 'not-yours:'||coalesce(t.claimed_by,'(unclaimed)');
  END IF;

  v_kind := coalesce(p_kind, t.park_kind);
  IF v_kind IS NULL THEN RETURN 'need-kind'; END IF;

  -- ⚠ RESTORED FROM MIGRATION 116, WHICH THIS FUNCTION'S PREVIOUS DEFINITION SILENTLY DROPPED.
  -- `IS NOT DISTINCT FROM` rather than `=` because a row parked before `parked_reason` was populated
  -- holds NULL, and NULL = NULL is NULL — which would make the carry-forward branch unreachable for
  -- exactly the oldest rows, the ones most likely to carry a summary nobody has looked at.
  -- ⚠ AND IT TESTS `status`, NOT merely the presence of a reason: migration 082 settled that the
  -- answer to "is this parked?" is the status.
  v_same_park := (t.status = 'parked' AND t.parked_reason IS NOT DISTINCT FROM p_reason);

  v_sum := nullif(btrim(coalesce(p_summary,'')),'');
  IF v_sum IS NULL AND v_same_park THEN
    v_sum := t.park_summary;                       -- the lock-restoration case, unchanged
  ELSIF v_sum IS NULL AND t.park_summary IS NOT NULL THEN
    -- The row HAS a sentence and the reason it described is gone. Refuse and say which.
    RETURN 'summary-superseded';
  END IF;
  v_verdict := ledger.park_summary_verdict(v_sum);
  IF v_verdict <> 'ok' THEN RETURN 'summary-'||v_verdict; END IF;

  -- ⚠ CARRY FORWARD, BUT DO NOT INVENT — migration 101's rule, unchanged. A re-park of a row that
  -- already has a condition keeps it; a row parked before 101 has none and must ASK rather than be
  -- silently left conditionless for ever. The coalesce alone cannot tell those apart, so the verdict
  -- is taken on the RESULT.
  -- ⚠ ALSO RESTORED FROM 116, and it is the worse of the two when stale: scripts/park-conditions.sh
  -- RE-RUNS the condition, so a superseded one is not merely read wrongly — it is EXECUTED and
  -- answers confidently about the wrong question.
  v_cond := nullif(btrim(coalesce(p_condition,'')),'');
  IF v_cond IS NULL AND v_same_park THEN
    v_cond := t.park_condition;
  ELSIF v_cond IS NULL AND t.park_condition IS NOT NULL THEN
    RETURN 'condition-superseded';
  END IF;
  v_verdict := ledger.park_condition_verdict(v_cond);
  IF v_verdict <> 'ok' THEN RETURN 'condition-'||v_verdict; END IF;

  UPDATE ledger.ticket
     SET status='parked', parked_reason=p_reason, park_summary=v_sum, park_condition=v_cond,
         parked_at=now(), park_kind=v_kind, updated_at=now(),
         -- ⚠ THE PO DOES NOT BECOME THE AUTHOR. See the header: `parked_by` is the author of the
         -- assessment and the retired agent really did write it. Who ACTED is the ticket_event row
         -- below — 107's own parked_by / adjudicated_by split, applied to the verb.
         parked_by = CASE WHEN v_as_po THEN t.parked_by ELSE me END,
         -- ── 3. THE ASK LANDS IN THE FIELD THE SPEC NAMES ────────────────────────────────────────
         -- Migration 112 added `ask` and `waiting_on` and backfilled them ONCE. Nothing has written
         -- them since, so on a row parked after 112 the spec §2 field is permanently NULL while
         -- `park_summary` carries the text — two columns for one fact, drifting from the first write.
         -- Derived here exactly as 112 derived the backfill, so they cannot disagree.
         -- ⚠ THE TRIGGER CANNOT FIRE ON THIS: park_summary_verdict has already refused an empty or
         -- contentless summary above, so `ask` is non-empty by the time this runs. That ordering is
         -- load-bearing — moving this write above the verdict would turn a returned verdict string
         -- into a raised exception.
         ask = v_sum,
         waiting_on = CASE v_kind
                        WHEN 'blocked_on_owner' THEN 'owner'
                        WHEN 'blocked_on_other' THEN 'other'
                        ELSE NULL
                      END
   WHERE id=p_id;
  INSERT INTO ledger.ticket_event(ticket_id,verb,actor,detail)
    VALUES (p_id,'park',me,jsonb_build_object(
      'reason',p_reason,'kind',v_kind,'summary',v_sum,'condition',v_cond,
      'as_product_owner', v_as_po, 'adjudicated_from', t.adjudicated_from));
  RETURN 'ok';
END $$;


--
-- Name: FUNCTION park(p_id text, p_reason text, p_kind ledger.park_kind, p_summary text, p_condition text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.park(p_id text, p_reason text, p_kind ledger.park_kind, p_summary text, p_condition text) IS 'Parks a ticket. A re-park with a NEW reason and no summary is REFUSED (summary-superseded) rather than carrying the old sentence forward — migration 116, restored here after 117 redefined this function from a stale copy. The condition sibling is condition-superseded.';


--
-- Name: park_condition_verdict(text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.park_condition_verdict(p_condition text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
DECLARE v text;
BEGIN
  v := nullif(btrim(coalesce(p_condition,'')),'');
  IF v IS NULL THEN RETURN 'need-condition'; END IF;
  -- An explicit declaration that nothing can check this. The reason travels with it; this only
  -- settles that the author CHOSE rather than omitted. 42 of 74 parks are legitimately here.
  IF lower(v) = 'none' OR lower(v) LIKE 'none:%' THEN RETURN 'ok'; END IF;
  -- No shell metacharacters — the re-runner refuses them, and refusing here is where the author
  -- can still fix it rather than in a sweep nobody watches.
  IF v ~ '[;|&`$()<>]' THEN RETURN 'not-runnable'; END IF;
  -- Exactly the shape `scripts/park-conditions.sh` can actually run.
  IF v ~ '^bash[[:space:]]+scripts/[A-Za-z0-9_.-]+([[:space:]]+[A-Za-z0-9_.:/-]+)*$' THEN
    RETURN 'ok';
  END IF;
  RETURN 'not-runnable';
END $_$;


--
-- Name: FUNCTION park_condition_verdict(p_condition text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.park_condition_verdict(p_condition text) IS 'ok | need-condition | not-runnable. Accepts a plain `bash scripts/<file> [verb]` invocation or an explicit `none[: why]`. SHAPE ONLY — it cannot tell a check that reads the authoritative copy from one that reads a copy that merely looks right. See migration 101.';


--
-- Name: park_is_adjudicated_to_the_product_owner(ledger.ticket_status, text, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.park_is_adjudicated_to_the_product_owner(p_status ledger.ticket_status, p_claimed_by text, p_adjudicated_from text, p_actor text) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
  SELECT p_status = 'parked'
     AND p_claimed_by IS NULL
     AND p_adjudicated_from IS NOT NULL
     AND EXISTS (SELECT 1 FROM ledger.agent
                  WHERE name = p_actor
                    AND role = 'delivery-lead'
                    AND offboarded IS NULL)
$$;


--
-- Name: FUNCTION park_is_adjudicated_to_the_product_owner(p_status ledger.ticket_status, p_claimed_by text, p_adjudicated_from text, p_actor text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.park_is_adjudicated_to_the_product_owner(p_status ledger.ticket_status, p_claimed_by text, p_adjudicated_from text, p_actor text) IS 'Spec §3(b), for the state migration 107 leaves behind. TRUE only for a parked row with no holder that was adjudicated away from a provably retired one, asked by an ACTIVE delivery-lead. ⚠ adjudicated_from is what makes this a carve-out rather than a loosening: a mid-claim row and a row whose claimed_by a mirror wiped are both unowned and neither is adjudicated, so neither is reachable through here.';


--
-- Name: park_summary_verdict(text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.park_summary_verdict(p_summary text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  WITH s AS (SELECT btrim(coalesce(p_summary,'')) AS v),
       -- Tokens that carry no information about THIS ticket. Deliberately short: every word here
       -- is one a reader could have guessed without opening the ticket.
       stop AS (SELECT ARRAY[
         'blocked','block','blocker','blockers','blocking','waiting','wait','pending','stuck',
         'external','factors','factor','other','others','something','someone','stuff','things',
         'thing','issues','issue','reasons','reason','various','several','some','until','still',
         'currently','now','the','a','an','on','in','of','to','for','and','or','is','it','this',
         'that','work','ticket','yet','not','done','tbd','n/a','na','todo'
       ] AS w)
  SELECT CASE
    WHEN (SELECT v FROM s) = '' THEN 'empty'
    -- ⚠ A CAP ON THE SUMMARY IS NOT A CAP ON THE REASON, and the difference is the whole design.
    -- The ticket forbids imposing a length limit and calling it done — the 7,133-character reason on
    -- infra_preprod_destructive_ops_need_the_owners_token is GOOD writing, detailed because its
    -- subject is. `parked_reason` stays unbounded. This bounds only the one-sentence field, because
    -- a "summary" that runs to a page is the detail again and puts the reader back where he started.
    WHEN length((SELECT v FROM s)) > 400 THEN 'too-long'
    WHEN (SELECT count(*) FROM (
            SELECT unnest(regexp_split_to_array(lower((SELECT v FROM s)), '[^a-z0-9/-]+')) AS t
         ) k WHERE k.t <> '' AND k.t NOT IN (SELECT unnest(w) FROM stop)) < 3 THEN 'contentless'
    ELSE 'ok'
  END
$$;


--
-- Name: FUNCTION park_summary_verdict(p_summary text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.park_summary_verdict(p_summary text) IS 'ok | empty | too-long | contentless. A FLOOR, not a quality judgement: it rejects a summary made entirely of blocker-shaped filler and cannot tell a specific summary from a plausible one. The real test is a human reading it cold — see the ticket''s own success criterion.';


--
-- Name: priority_of(text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.priority_of(p_raw text) RETURNS smallint
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT coalesce(ledger.priority_of_strict(p_raw), 3::smallint)
$$;


--
-- Name: priority_of_strict(text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.priority_of_strict(p_raw text) RETURNS smallint
    LANGUAGE sql IMMUTABLE
    AS $_$
  SELECT CASE lower(btrim(coalesce(p_raw,'')))
           WHEN 'critical' THEN 1::smallint
           WHEN 'high'     THEN 2::smallint
           WHEN 'medium'   THEN 3::smallint
           WHEN 'low'      THEN 4::smallint
           -- ⚠ `0` MEANS HIGHEST AND MUST NOT FALL THROUGH — 19's finding, kept verbatim in effect.
           -- One ticket on main spells its priority `0`; letting it reach the fallback would silently
           -- DOWNGRADE a critical ticket to medium.
           WHEN '0'        THEN 1::smallint
           ELSE CASE WHEN btrim(coalesce(p_raw,'')) ~ '^[0-9]+$'
                      AND btrim(p_raw)::int BETWEEN 1 AND 5
                     THEN btrim(p_raw)::smallint
                     -- ⚠ THE ONE LINE THAT DIFFERS FROM 19: it returned 3 here, which is why the
                     -- coercion could never be seen. NULL says "unrecognised" without deciding what
                     -- to do about it.
                     ELSE NULL::smallint END
         END
$_$;


--
-- Name: promote_reviewed_ticket(text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.promote_reviewed_ticket(p_id text, p_status text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE v_actor text := session_user::text; v_held ledger.ticket_status;
BEGIN
  -- ⚠ THE DESTINATION IS A CLOSED LIST, AND draft/reviewed/in_progress/passing/archived ARE NOT ON
  -- IT. "I choose where they go from there" means the backlog, the ready frontier, or the bin.
  -- Letting this verb write `in_progress` would create an owned-by-nobody ticket that
  -- `owned_iff_in_progress` refuses anyway -- better to name the closed list than to hand the caller
  -- a constraint violation.
  IF p_status NOT IN ('not_started','selected','wont_do') THEN
    RETURN 'bad-destination:' || coalesce(p_status,'<null>');
  END IF;
  SELECT status INTO v_held FROM ledger.ticket WHERE id = p_id;
  IF v_held IS NULL THEN RETURN 'no-such-ticket'; END IF;
  IF v_held <> 'reviewed' THEN RETURN 'not-reviewed:' || v_held::text; END IF;
  UPDATE ledger.ticket SET status = p_status::ledger.ticket_status, updated_at = now() WHERE id = p_id;
  INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
  VALUES (p_id, 'promoted', v_actor, jsonb_build_object('to', p_status));
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN 'refused:' || SQLSTATE || ':' || left(SQLERRM, 120);
END $$;


--
-- Name: FUNCTION promote_reviewed_ticket(p_id text, p_status text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.promote_reviewed_ticket(p_id text, p_status text) IS 'reviewed -> not_started | selected | wont_do. Owner-only by GRANT. Writes status DIRECTLY rather than through owner_set_field, because an override never retires for a status git cannot emit and would leave a permanent ageing row in v_owner_override_pending. See migration 34.';


--
-- Name: raise_epic(jsonb); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.raise_epic(p jsonb) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE
  v_epic   jsonb := p->'epic';
  v_child  jsonb;
  v_v      text;
  v_epicid text;
  v_n      int := 0;
  v_fail   text;
BEGIN
  IF v_epic IS NULL OR jsonb_typeof(v_epic) <> 'object' THEN RETURN 'need-epic-object'; END IF;
  IF p ? 'children' AND jsonb_typeof(p->'children') <> 'array' THEN RETURN 'children-not-a-list'; END IF;

  v_epicid := nullif(btrim(coalesce(v_epic->>'id','')), '');
  IF v_epicid IS NULL THEN RETURN 'need-epic-id'; END IF;

  -- ⚠⚠ THE INNER BLOCK IS WHAT GIVES US *BOTH* ATOMICITY AND A VERDICT STRING, AND IT IS NOT
  -- COSMETIC. A plpgsql `EXCEPTION` clause opens an implicit savepoint, so raising inside it rolls
  -- back every row written since `BEGIN` — while the handler still returns normally. My first
  -- version raised to the CALLER: atomic, but it surfaced as `ERROR: raise_epic_child_refused:…`,
  -- breaking the contract this file's header states in its own second paragraph.
  -- ⚠ DRIVEN, and the distinction matters: a Postgres error from a child's typo is
  -- INDISTINGUISHABLE at the call site from the database being unwell, whereas a verdict says which
  -- child and why. Variables are memory, not table state, so `v_fail` survives the rollback that
  -- discards the rows — which is the whole trick.
  BEGIN
    v_v := ledger.raise_ticket(v_epic);
    IF v_v <> 'ok' THEN RETURN 'epic:'||v_v; END IF;

    FOR v_child IN SELECT jsonb_array_elements(coalesce(p->'children','[]'::jsonb)) LOOP
      -- The child's parent is SET here rather than trusted from the payload: an epic raise whose
      -- child names a different parent is a mistake, not an instruction.
      v_v := ledger.raise_ticket(v_child || jsonb_build_object('parent', v_epicid));
      IF v_v <> 'ok' THEN
        v_fail := coalesce(nullif(btrim(coalesce(v_child->>'id','')), ''), '(child with no id)')||': '||v_v;
        -- RAISE, not RETURN — the exception is what discards the epic and any earlier children.
        RAISE EXCEPTION 'child-refused' USING ERRCODE = 'data_exception';
      END IF;
      v_n := v_n + 1;
    END LOOP;
  EXCEPTION WHEN data_exception THEN
    -- Everything written since the inner BEGIN is gone. Say which child and why.
    RETURN 'child-refused:'||coalesce(v_fail,'(unknown)')||' — nothing was written';
  END;

  RETURN 'ok:'||v_n::text;
END;
$$;


--
-- Name: raise_request(text, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.raise_request(p_raw text, p_note text DEFAULT ''::text, p_actor text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE v_actor text; v_proof text; v_seq bigint;
BEGIN
  SELECT actor, proof INTO v_actor, v_proof FROM ledger.resolve_actor(p_actor);
  -- ⚠ REFUSE BLANK, DO NOT SILENTLY DROP IT. A blank row is indistinguishable from a miscount later,
  -- and this table exists to make the count trustworthy.
  IF btrim(coalesce(p_raw,'')) = '' THEN RETURN 'empty'; END IF;
  -- ⚠ THE TEXT IS STORED UNCHANGED. No trim, no collapse of whitespace, no normalisation. The whole
  -- value of this row is that it is the owner's words and not somebody's reading of them.
  INSERT INTO ledger.request(raw, note, raised_by)
  VALUES (p_raw, nullif(btrim(coalesce(p_note,'')), ''), v_actor)
  RETURNING seq INTO v_seq;
  INSERT INTO ledger.admin_event(entity, entity_id, verb, actor, actor_proof)
  VALUES ('request', v_seq::text, 'raised', v_actor, v_proof);
  RETURN 'raised:' || v_seq;
END $$;


--
-- Name: raise_ticket(jsonb); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.raise_ticket(p jsonb) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE
  v_actor  text;
  v_proof  text;
  v_id     text := nullif(btrim(coalesce(p->>'id','')), '');
  v_title  text := nullif(btrim(coalesce(p->>'title','')), '');
  v_area   text := nullif(btrim(coalesce(p->>'area','')), '');
  v_status text := coalesce(nullif(btrim(coalesce(p->>'status','')), ''), 'not_started');
  v_prio   smallint;
  v_parent text := nullif(btrim(coalesce(p->>'parent','')), '');
  v_dep    text;
  v_is_po  boolean;
  v_is_own boolean;
BEGIN
  SELECT actor, proof INTO v_actor, v_proof FROM ledger.resolve_actor(p->>'raised_by');

  IF v_id    IS NULL THEN RETURN 'need-id';    END IF;
  IF v_title IS NULL THEN RETURN 'need-title'; END IF;
  IF v_area  IS NULL THEN RETURN 'need-area';  END IF;

  -- ⚠ THE TITLE'S *LENGTH* IS CHECKED HERE BECAUSE THE TABLE ALREADY CHECKS IT, AND A CONSTRAINT
  -- VIOLATION IS NOT A VERDICT. `ticket_title_check` is `length BETWEEN 8 AND 600`; without this,
  -- a three-character title aborts the transaction with a Postgres error instead of returning a
  -- string the caller can branch on — and inside `raise_epic` that abort is indistinguishable from
  -- the deliberate rollback, so a typo in one child would report as an atomicity failure.
  -- ⚠ FOUND BY DRIVING IT, NOT BY READING: my own fixture used the title "t" and the function blew
  -- up where it should have declined. The header two hundred lines above promises "verdict strings,
  -- not exceptions"; this is the line that makes that true for the commonest mistake in a payload.
  IF length(v_title) < 8 OR length(v_title) > 600 THEN
    RETURN 'title-length:'||length(v_title)::text||' (needs 8..600)';
  END IF;

  -- ⚠ EXISTS is checked before anything is written, and again by the primary key. Both, because the
  -- verdict string is what the caller reads and 'exists' is more use than a constraint violation.
  IF EXISTS (SELECT 1 FROM ledger.ticket WHERE id = v_id) THEN RETURN 'exists:'||v_id; END IF;

  IF NOT EXISTS (SELECT 1 FROM ledger.area WHERE name = v_area) THEN
    RETURN 'uncontrolled-area:'||v_area;
  END IF;

  -- ⚠ A VERIFICATION THAT IS NOT A LIST IS REFUSED, not coerced. `check-ticket-verification-is-a-list.sh`
  -- is the file-side half of this rule and a raise must not create rows that gate would reject —
  -- the export has to round-trip.
  IF p ? 'verification' AND jsonb_typeof(p->'verification') <> 'array' THEN
    RETURN 'verification-not-a-list:'||jsonb_typeof(p->'verification');
  END IF;

  IF v_parent IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ledger.ticket WHERE id = v_parent) THEN
    RETURN 'unknown-parent:'||v_parent;
  END IF;

  FOR v_dep IN SELECT jsonb_array_elements_text(coalesce(p->'depends_on','[]'::jsonb)) LOOP
    IF NOT EXISTS (SELECT 1 FROM ledger.ticket WHERE id = v_dep) THEN
      RETURN 'unknown-dependency:'||v_dep;
    END IF;
  END LOOP;

  -- §3 + §8. Only these two are reachable by a raise; everything else is a later transition.
  IF v_status NOT IN ('not_started','selected') THEN
    RETURN 'bad-status:not_started|selected';
  END IF;

  v_is_own := (v_actor = 'ledger_owner' AND v_proof = 'connection');
  v_is_po  := (v_proof = 'connection'
               AND EXISTS (SELECT 1 FROM ledger.agent
                            WHERE name = v_actor AND role = 'delivery-lead' AND offboarded IS NULL));

  IF v_status = 'selected' AND NOT (v_is_po OR v_is_own) THEN
    -- The verdict names the SPEC rule rather than the enum, so the message survives the rename.
    RETURN 'ready-is-the-pos-move:'||v_actor;
  END IF;

  -- ⚠ The actor must be someone. An unrostered connection is not a session the board can attribute,
  -- and `claimed_by`/`raised_by` carrying an unrostered name fails check-roster-coverage.
  IF NOT (v_is_own OR v_proof = 'console-asserted'
          OR EXISTS (SELECT 1 FROM ledger.agent WHERE name = v_actor AND offboarded IS NULL)) THEN
    RETURN 'raiser-not-in-roster:'||v_actor;
  END IF;

  -- ⚠ ONE FIELD, ONE CONVERSION. This used to cast the payload's priority straight to smallint,
  -- which threw on every word priority while the MIRROR path resolved the same words through this
  -- very function. See migration 144's header for the measurement and the case it does not cover.
  -- ⚠ THE OLD EXPRESSION IS DELIBERATELY NOT QUOTED HERE — see the header's note on why.
  v_prio := ledger.priority_of(p->>'priority');

  INSERT INTO ledger.ticket
    (id, title, area, status, priority, user_visible_behavior, notes,
     verification, verification_command, parent, depends_on, solo, raised_by, extra)
  VALUES
    (v_id, v_title, v_area, v_status::ledger.ticket_status, v_prio,
     coalesce(p->>'user_visible_behavior',''), coalesce(p->>'notes',''),
     coalesce((SELECT array_agg(x) FROM jsonb_array_elements_text(coalesce(p->'verification','[]'::jsonb)) x),
              ARRAY[]::text[]),
     nullif(btrim(coalesce(p->>'verification_command','')), ''),
     v_parent,
     coalesce((SELECT array_agg(x) FROM jsonb_array_elements_text(coalesce(p->'depends_on','[]'::jsonb)) x),
              ARRAY[]::text[]),
     coalesce((p->>'solo')::boolean, false),
     v_actor,
     -- ⚠⚠ MIGRATION 155. THIS WAS `coalesce(p->'extra','{}'::jsonb)` — the explicit `extra` object
     -- and NOTHING ELSE, so every top-level key this function does not consume was DISCARDED.
     -- `mirror_ticket` does not behave that way: `LEDGER_TICKET_PAYLOAD_JQ` builds `extra` as the
     -- file MINUS the modelled keys, so an unmodelled key survives a mirror. Two write paths
     -- disagreed about the same keys.
     --
     -- ⚠ MEASURED 2026-09-16, 4,399 rows: 452 carry `problem` in `extra` and 250 carry `scope`,
     -- all via the FILE path. A ticket raised through this function carried NO extra keys at all.
     -- 399 files on main hold `problem`, 247 hold `scope`.
     --
     -- ⚠ THE CUTOVER DOES NOT EXPOSE THIS, IT ACTIVATES IT. While files exist the loss is
     -- recoverable — the next sync mirrors the keys back. After step 7 there is no file, so the
     -- discard is permanent and total, and the only thing between that and silence was a printed
     -- sentence asking the author to notice.
     --
     -- ⚠ FIXED HERE AND NOT IN `ledger-db.sh`'s jq, DELIBERATELY. The console and any future caller
     -- raise through this function; a fix in one client leaves every other caller lossy, which is
     -- the asymmetry this repairs rebuilt one layer down.
     --
     -- ⚠ THE EXPLICIT `extra` IS OVERLAID SECOND SO IT WINS ON A COLLISION. A caller that sends both
     -- a top-level key and the same key inside `extra` has said the second one deliberately.
     --
     -- ⚠ THE SUBTRACTION LIST IS EXACTLY THE KEYS THIS FUNCTION CONSUMES — derived by grepping its
     -- own body for `p->>'…'` / `p->'…'`, not from memory. If a future migration teaches this
     -- function a new key, IT MUST BE ADDED HERE TOO, or the value lands in both the column and the
     -- blob and the two can then disagree.
     ( (p - ARRAY['id','title','area','status','priority','user_visible_behavior','notes',
                  'verification','verification_command','parent','depends_on','solo','raised_by',
                  'extra'])
       || coalesce(p->'extra','{}'::jsonb) ));

  -- ⚠ ONE EVENT, WITH THE FULL PAYLOAD. The files were kept in git because a requirement change
  -- appeared in a diff; the event log is the replacement, so the raise must record what was raised
  -- rather than merely that a raise happened.
  INSERT INTO ledger.ticket_event (ticket_id, verb, actor, detail)
  VALUES (v_id, 'raised', v_actor,
          jsonb_build_object('proof', v_proof, 'status', v_status, 'payload', p));

  RETURN 'ok';
END;
$$;


--
-- Name: reclassify_park(text, ledger.park_kind, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.reclassify_park(p_id text, p_kind ledger.park_kind, p_why text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE t ledger.ticket%ROWTYPE; me text := session_user; v_was ledger.park_kind; v_as_po boolean;
        v_ask text;
BEGIN
  IF p_kind IS NULL THEN RETURN 'need-kind'; END IF;
  IF nullif(btrim(coalesce(p_why,'')),'') IS NULL THEN RETURN 'need-why'; END IF;
  SELECT * INTO t FROM ledger.ticket WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'no-such-ticket'; END IF;
  -- ⚠ KEYED ON STATUS — migration 082 measured all three options; status is exact in both directions.
  IF t.status <> 'parked' THEN RETURN 'not-parked'; END IF;

  -- ⚠ THIS ONE GATES ON parked_by, NOT claimed_by, and that is spec §3(a)'s "one identity field
  -- decides" showing through: on an adjudicated row parked_by is the RETIRED author, so the PO is
  -- refused here for a different reason than at the other two verbs and by a different column. The
  -- carve-out is the same either way, which is the point of putting it in one predicate.
  v_as_po := ledger.park_is_adjudicated_to_the_product_owner(t.status, t.claimed_by, t.adjudicated_from, me);
  IF t.parked_by IS DISTINCT FROM me AND NOT v_as_po THEN
    RETURN 'not-yours:'||coalesce(t.parked_by,'(nobody)');
  END IF;

  v_was := t.park_kind;
  IF v_was IS NOT DISTINCT FROM p_kind THEN RETURN 'unchanged:'||coalesce(v_was::text,'(null)'); END IF;

  -- ⚠⚠ MOVING A ROW ONTO THE OWNER QUEUE NEEDS AN ASK, AND THIS VERB HAS NO ARGUMENT FOR ONE.
  -- `waiting_on` must move with the kind or the two disagree from the next read onward. But
  -- reclassifying TO blocked_on_owner is precisely the transition migration 112's trigger forbids
  -- without an ask — and a trigger RAISES, so it would turn this verb's returned verdict into an
  -- exception the caller never asked for. Refused as a verdict instead, in the same shape as
  -- `need-kind` and `need-why` above.
  --
  -- ⚠ THE CARRY-FORWARD IS A COPY, NOT A PARAPHRASE, and that distinction is 112's: it backfilled
  -- `ask` from `park_summary` ONLY, and forbids deriving one from `parked_reason` by name — "a
  -- generated summary of a park reason is a paraphrase of the one field that must not be
  -- paraphrased". Same source here, same rule. A row with neither is asked, not invented for.
  v_ask := coalesce(nullif(btrim(coalesce(t.ask,'')),''), nullif(btrim(coalesce(t.park_summary,'')),''));
  IF p_kind = 'blocked_on_owner' AND v_ask IS NULL THEN RETURN 'need-ask'; END IF;

  -- ⚠ `updated_at` MOVES AND `parked_at` DOES NOT — 082's rule.
  UPDATE ledger.ticket
     SET park_kind = p_kind,
         ask = coalesce(v_ask, t.ask),
         waiting_on = CASE p_kind
                        WHEN 'blocked_on_owner' THEN 'owner'
                        WHEN 'blocked_on_other' THEN 'other'
                        ELSE NULL
                      END,
         updated_at = now()
   WHERE id = p_id;
  INSERT INTO ledger.ticket_event(ticket_id,verb,actor,detail)
    VALUES (p_id,'reclassify_park',me,
            jsonb_build_object('from', v_was, 'to', p_kind, 'why', p_why,
                               'as_product_owner', v_as_po));
  RETURN 'ok';
END $$;


--
-- Name: FUNCTION reclassify_park(p_id text, p_kind ledger.park_kind, p_why text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.reclassify_park(p_id text, p_kind ledger.park_kind, p_why text) IS 'Correct the KIND of your own existing park, and nothing else. Never touches the reason, the date, the owner or the status; refuses a ticket that is not parked rather than parking it. Exists because calling park() again would restamp parked_at and demand the full reason back. See migration 55.';


--
-- Name: record_issue(text, integer); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.record_issue(p_id text, p_issue integer) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE
  t ledger.ticket%ROWTYPE;
  me text := session_user;
BEGIN
  IF p_issue IS NULL OR p_issue <= 0 THEN
    RETURN 'not-an-issue-number:'||coalesce(p_issue::text,'(null)');
  END IF;

  SELECT * INTO t FROM ledger.ticket WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'no-such-ticket'; END IF;

  -- ⚠ ATTRIBUTION, NOT AUTHORISATION: the trace below is the control, and a trace naming something
  -- that is not an agent records nothing. Same rule as amend_requirement.
  IF NOT EXISTS (SELECT 1 FROM ledger.v_agent WHERE name = me) THEN
    RETURN 'not-a-rostered-agent:'||me;
  END IF;

  -- Re-recording the same number is a safe no-op, so a retry after a half-completed claim works.
  IF t.issue IS NOT NULL AND t.issue = p_issue THEN RETURN 'already:'||p_issue::text; END IF;

  -- ⚠ A DIFFERENT NUMBER IS REFUSED, NOT OVERWRITTEN. Two issue numbers for one ticket is a real
  -- state (the `open` verb can mint a duplicate), and silently preferring the newer one would pick
  -- a winner between two OWNER records with nothing downstream able to notice.
  IF t.issue IS NOT NULL THEN
    RETURN 'already-different:'||t.issue::text;
  END IF;

  UPDATE ledger.ticket SET issue = p_issue, updated_at = now() WHERE id = p_id;

  INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
    VALUES (p_id, 'issue', me, jsonb_build_object('issue', p_issue, 'from', NULL::text));

  RETURN 'ok';
END $$;


--
-- Name: FUNCTION record_issue(p_id text, p_issue integer); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.record_issue(p_id text, p_issue integer) IS 'Records a ticket''s GitHub issue number on the row. Row-native, because the number used to reach the row only through a ticket FILE via mirror_ticket and there are no files. FILLS ONLY: a different number already recorded is REFUSED rather than overwritten, because two issue numbers for one ticket means a duplicate issue or a confused caller, and picking a winner between two owner records is unrecoverable. Deliberately NOT part of amend_requirement, whose whitelist excludes `issue` so that a requirement editor cannot forge an ownership pointer.';


--
-- Name: refuse_a_passing_finish_without_a_verification_pointer(); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.refuse_a_passing_finish_without_a_verification_pointer() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Not a passing finish: nothing to say. ⚠ THIS IS ALSO THE `wont_do` ARM, and it is deliberate —
  -- abandonment needs no verification pointer, and 46 of the 49 wont_do rows have none.
  IF NEW.archived_from_status IS DISTINCT FROM 'passing' THEN RETURN NEW; END IF;

  -- A pointer is present: the rule is satisfied.
  IF NEW.verified_by_pr IS NOT NULL THEN RETURN NEW; END IF;

  -- ⚠ THE RATCHET. The row is arriving at (passing, no pointer). Refuse only if it was not ALREADY
  -- there — a legacy row re-written for any other reason is none of this rule's business.
  IF TG_OP = 'UPDATE'
     AND OLD.archived_from_status IS NOT DISTINCT FROM 'passing'
     AND OLD.verified_by_pr IS NULL THEN
    RETURN NEW;
  END IF;

  -- ⚠ See the header: an ON CONFLICT insert fires this trigger before the conflict is seen.
  IF TG_OP = 'INSERT' AND EXISTS (SELECT 1 FROM ledger.ticket t WHERE t.id = NEW.id) THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION
    'ticket % cannot finish as passing with no verified_by_pr. The required CI check on the PR is '
    'what verifies a ticket, so the PR NUMBER is the evidence and the row is now the only place it '
    'is kept. Record it and retry:  "verified_by_pr": <the number gh pr create printed> -- never '
    'from memory. (A wont_do finish needs no pointer and is accepted.)',
    NEW.id
    USING ERRCODE = 'integrity_constraint_violation';
END
$$;


--
-- Name: FUNCTION refuse_a_passing_finish_without_a_verification_pointer(); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.refuse_a_passing_finish_without_a_verification_pointer() IS 'Ratchet: refuses a row ARRIVING at archived_from_status=''passing'' with verified_by_pr NULL. Rows already in that state are exempt by construction — 3,230 legacy rows on 2026-09-16 whose PR numbers were never recorded. ⚠ Do not "tidy" this into a CHECK constraint: a validated one is impossible while those rows exist, and a NOT VALID one reads as enforced without ever having been tested against the table.';


--
-- Name: refuse_comment_rewrite(); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.refuse_comment_rewrite() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'ledger.comment is append-only: DELETE is refused. A comment that was wrong is answered, never removed.'
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF NEW.body <> OLD.body OR NEW.author <> OLD.author
     OR NEW.author_kind <> OLD.author_kind OR NEW.at <> OLD.at THEN
    RAISE EXCEPTION 'ledger.comment: only the review columns may change. body/author/author_kind/at are fixed once written.'
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END $$;


--
-- Name: refuse_mutation(); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.refuse_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION
    'ledger.% is append-only: % is refused. History is the product here — correct a wrong fact by appending the correction, never by editing the record of it.',
    TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'restrict_violation';
END $$;


--
-- Name: release_claim(text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.release_claim(p_id text, p_reason text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE t ledger.ticket%ROWTYPE; me text := session_user;
BEGIN
  IF nullif(btrim(coalesce(p_reason,'')),'') IS NULL THEN RETURN 'need-reason'; END IF;
  SELECT * INTO t FROM ledger.ticket WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'no-such-ticket'; END IF;
  -- ⚠ ARCHIVED FIRST, AND NOW ALSO BEFORE THE ACTOR CHECK. It must refuse even for the row's own
  -- claimant, because the harm is the lost record of who delivered it, not who is asking — and
  -- since it writes nothing, no caller needs authority to be told so.
  IF t.status = 'archived' THEN RETURN 'archived:claimed_by is the only record of who delivered this'; END IF;
  IF t.claimed_by IS NULL            THEN RETURN 'already-unassigned'; END IF;
  IF t.claimed_by IS DISTINCT FROM me THEN RETURN 'not-yours:'||t.claimed_by; END IF;
  IF t.status = 'in_progress'        THEN RETURN 'in-progress:flip the status back before releasing'; END IF;
  -- ⚠ HERE, AND NOT EARLIER. Everything above this line returns without writing.
  IF NOT EXISTS (SELECT 1 FROM ledger.agent WHERE name = me AND offboarded IS NULL)
    THEN RETURN 'not-an-active-agent:'||me; END IF;
  UPDATE ledger.ticket
     SET claimed_by = NULL, claimed_at = NULL, updated_at = now()
   WHERE id = p_id;
  INSERT INTO ledger.ticket_event(ticket_id,verb,actor,detail)
    VALUES (p_id,'release',me,jsonb_build_object('reason',p_reason));
  RETURN 'ok';
END $$;


--
-- Name: release_retired_claim(text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.release_retired_claim(p_id text, p_reason text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE t ledger.ticket%ROWTYPE; me text := session_user; v_off timestamptz;
BEGIN
  IF nullif(btrim(coalesce(p_reason,'')),'') IS NULL THEN RETURN 'need-reason'; END IF;
  SELECT * INTO t FROM ledger.ticket WHERE id = p_id FOR UPDATE;
  IF NOT FOUND                        THEN RETURN 'no-such-ticket'; END IF;
  IF t.status = 'archived'            THEN RETURN 'archived:claimed_by is the only record of who delivered this'; END IF;
  IF t.claimed_by IS NULL             THEN RETURN 'already-unassigned'; END IF;
  IF t.status = 'in_progress'         THEN RETURN 'in-progress:flip the status back before releasing'; END IF;

  -- ⚠ THE WHOLE AUTHORISATION. An agent absent from the roster has never been registered and is not
  -- "retired" — refuse rather than guess, or this becomes a way to free a claim by misspelling it.
  SELECT offboarded INTO v_off FROM ledger.agent WHERE name = t.claimed_by;
  IF NOT FOUND                        THEN RETURN 'holder-not-in-roster:'||t.claimed_by; END IF;
  IF v_off IS NULL                    THEN RETURN 'holder-is-active:'||t.claimed_by||' — use release_claim as that agent'; END IF;

  -- Everything above this line returns without writing.
  UPDATE ledger.ticket
     SET claimed_by = NULL, claimed_at = NULL, updated_at = now()
   WHERE id = p_id;
  INSERT INTO ledger.ticket_event(ticket_id,verb,actor,detail)
    VALUES (p_id,'release',me,
            jsonb_build_object('reason',p_reason,'released_from',t.claimed_by,'retired_at',v_off));
  RETURN 'ok';
END $$;


--
-- Name: FUNCTION release_retired_claim(p_id text, p_reason text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.release_retired_claim(p_id text, p_reason text) IS 'Frees a claim held by an OFFBOARDED agent. Refuses when the holder is still active (that is release_claim''s job, callable only by the holder), when the holder is absent from the roster, on archived rows, and on in_progress rows. Never touches parked_by, which is the author field.';


--
-- Name: resolve_actor(text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.resolve_actor(p_claimed text) RETURNS TABLE(actor text, proof text)
    LANGUAGE sql STABLE
    AS $$
  SELECT CASE WHEN session_user::text = 'ledger_console'
              THEN COALESCE(NULLIF(trim(p_claimed), ''), 'unknown-console-user')
              ELSE session_user::text END,
         CASE WHEN session_user::text = 'ledger_console'
              THEN 'console-asserted' ELSE 'connection' END;
$$;


--
-- Name: retire_satisfied_overrides(jsonb); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.retire_satisfied_overrides(p jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE v_id text; r record; n integer := 0; git_value text;
BEGIN
  v_id := p->>'id';
  IF v_id IS NULL THEN RETURN 0; END IF;
  FOR r IN SELECT field, value FROM ledger.owner_override WHERE ticket_id = v_id LOOP
    -- ⚠ KEY PRESENCE, NOT VALUE, DECIDES WHETHER GIT HAS AN OPINION AT ALL. A payload that omits
    -- the field is not git saying NULL -- it is a caller that did not send it, and mirror_ticket's
    -- own ON CONFLICT clause already makes exactly this distinction for `priority`. Treating an
    -- absent key as a value would retire overrides against payloads that never mentioned them,
    -- which is 25's defect wearing different clothes.
    CONTINUE WHEN NOT (p ? r.field);
    git_value := CASE r.field
                   WHEN 'priority' THEN ledger.priority_of(p->>'priority')::text
                   ELSE p->>r.field
                 END;
    IF git_value IS NOT DISTINCT FROM r.value THEN
      DELETE FROM ledger.owner_override WHERE ticket_id = v_id AND field = r.field;
      INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
        VALUES (v_id, 'override_retired', 'system',
                jsonb_build_object('field', r.field, 'value', r.value, 'why', 'git caught up'));
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END $$;


--
-- Name: retire_specialism(text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.retire_specialism(p_name text, p_actor text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE v_actor text; v_proof text; v_holders int;
BEGIN
  SELECT actor, proof INTO v_actor, v_proof FROM ledger.resolve_actor(p_actor);
  IF NOT EXISTS (SELECT 1 FROM ledger.specialism WHERE name = p_name) THEN RETURN 'no-such-specialism'; END IF;
  -- ⚠ REFUSE while somebody holds it, rather than cascading. Silently unassigning three agents
  -- because their specialism was retired is a change nobody asked for and nobody would see.
  SELECT count(*) INTO v_holders FROM ledger.agent_specialism WHERE specialism = p_name;
  IF v_holders > 0 THEN RETURN 'held-by:' || v_holders; END IF;
  UPDATE ledger.specialism SET retired_at = now() WHERE name = p_name;
  INSERT INTO ledger.admin_event(entity, entity_id, verb, actor, actor_proof)
  VALUES ('specialism', p_name, 'retired', v_actor, v_proof);
  RETURN 'retired';
END $$;


--
-- Name: retire_ticket(text, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.retire_ticket(p_id text, p_reason text, p_actor text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE
  v_actor text; v_proof text;
  v_held ledger.ticket_status; v_owner text; v_retired timestamptz;
  v_is_po boolean; v_is_own boolean;
  v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
BEGIN
  SELECT actor, proof INTO v_actor, v_proof FROM ledger.resolve_actor(p_actor);
  IF v_actor IS NULL THEN RETURN 'refused:no-actor'; END IF;

  -- ⚠ THE REASON IS MANDATORY AND IS CHECKED HERE AS WELL AS BY THE CONSTRAINT, because a
  -- constraint violation is not a verdict — 121's `title-length` arm is the precedent, and it was
  -- found by driving rather than by reading.
  IF v_reason IS NULL THEN RETURN 'refused:no-reason'; END IF;

  SELECT status, claimed_by, retired_at INTO v_held, v_owner, v_retired
    FROM ledger.ticket WHERE id = p_id;
  IF v_held IS NULL THEN RETURN 'refused:no-such-ticket'; END IF;
  IF v_retired IS NOT NULL THEN RETURN 'already-retired'; END IF;

  -- ⚠ DELIVERED WORK IS NOT RETIRABLE BY ANYONE. Hiding a `passing` or `archived` ticket would
  -- erase the record that something SHIPPED, which is the one thing this ledger exists to hold.
  -- Retirement is for rows that should not be on the board, never for work that is done.
  IF v_held IN ('passing','archived') THEN RETURN 'refused:delivered-work-is-not-retirable:'||v_held::text; END IF;

  v_is_own := (v_actor = 'ledger_owner' AND v_proof = 'connection');
  v_is_po  := (v_proof = 'connection'
               AND EXISTS (SELECT 1 FROM ledger.agent
                            WHERE name = v_actor AND role = 'delivery-lead' AND offboarded IS NULL));

  -- ⚠ YOU MAY NOT RETIRE WORK SOMEBODY ELSE HOLDS. A claim is a lock with a person behind it, and
  -- withdrawing it from under them is the "wrong owner just persists" failure class: nothing
  -- downstream can tell that the ticket they are working was withdrawn. The holder may retire their
  -- own; the PO and the owner may retire any, which is what makes an abandoned claim recoverable.
  IF v_owner IS NOT NULL AND v_owner <> v_actor AND NOT (v_is_po OR v_is_own) THEN
    RETURN 'refused:held-by:'||v_owner;
  END IF;

  UPDATE ledger.ticket
     SET retired_at = now(), retired_by = v_actor, retired_reason = v_reason, updated_at = now()
   WHERE id = p_id;

  INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
  VALUES (p_id, 'retired', v_actor,
          jsonb_build_object('proof', v_proof, 'reason', v_reason, 'status_when_retired', v_held::text));
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN 'refused:'||SQLSTATE||':'||left(SQLERRM,120);
END $$;


--
-- Name: review_comment(bigint); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.review_comment(p_seq bigint) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE v_actor text := session_user::text; v_kind text; v_done timestamptz;
BEGIN
  SELECT author_kind, reviewed_at INTO v_kind, v_done FROM ledger.comment WHERE seq = p_seq;
  IF v_kind IS NULL THEN RETURN 'no-such-comment'; END IF;
  -- ⚠ REVIEWING AN AGENT'S COMMENT IS A CATEGORY ERROR, NOT A NO-OP. Only an owner comment ever
  -- reads unreviewed, so answering `ok` here would let a screen "clear" something that was never
  -- flagged and report progress that did not happen.
  IF v_kind <> 'owner' THEN RETURN 'not-an-owner-comment'; END IF;
  IF v_done IS NOT NULL THEN RETURN 'already-reviewed'; END IF;
  UPDATE ledger.comment SET reviewed_at = now(), reviewed_by = v_actor WHERE seq = p_seq;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN 'refused:' || SQLSTATE || ':' || left(SQLERRM, 120);
END $$;


--
-- Name: review_ticket(text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.review_ticket(p_id text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE v_actor text := session_user::text; v_held ledger.ticket_status;
BEGIN
  SELECT status INTO v_held FROM ledger.ticket WHERE id = p_id;
  IF v_held IS NULL THEN RETURN 'no-such-ticket'; END IF;
  -- ⚠ ONLY FROM draft. Reviewing anything else is a category error, and answering `ok` to it would
  -- make the verb mean "set status to reviewed", which is the owner's move and not the PO's.
  IF v_held <> 'draft' THEN RETURN 'not-a-draft:' || v_held::text; END IF;
  UPDATE ledger.ticket SET status = 'reviewed', updated_at = now() WHERE id = p_id;
  INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
  VALUES (p_id, 'reviewed', v_actor, NULL);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN 'refused:' || SQLSTATE || ':' || left(SQLERRM, 120);
END $$;


--
-- Name: FUNCTION review_ticket(p_id text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.review_ticket(p_id text) IS 'draft -> reviewed. Granted to ledger_agent as well as ledger_console because the DELIVERY LEAD does the review and the PO is an agent. Refuses anything that is not currently draft.';


--
-- Name: set_lock_intent(text, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.set_lock_intent(p_id text, p_intent text, p_note text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE t ledger.ticket%ROWTYPE; me text := session_user;
        v_note text := nullif(btrim(coalesce(p_note, '')), '');
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ledger.agent WHERE name = me AND offboarded IS NULL)
    THEN RETURN 'not-an-active-agent:' || me; END IF;
  IF p_intent IS NULL OR p_intent NOT IN ('building', 'holding', 'travelling')
    THEN RETURN 'bad-intent:' || coalesce(p_intent, ''); END IF;
  IF p_intent = 'travelling' AND v_note IS NULL THEN RETURN 'travelling-needs-a-note'; END IF;
  SELECT * INTO t FROM ledger.ticket WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'no-such-ticket'; END IF;
  IF t.status IN ('archived', 'wont_do') THEN RETURN 'finished:' || t.status; END IF;
  IF t.claimed_by IS DISTINCT FROM me THEN RETURN 'not-yours:' || coalesce(t.claimed_by, '(unclaimed)'); END IF;
  IF coalesce(t.extra->>'lock_intent', '') = p_intent
     AND coalesce(t.extra->>'lock_intent_by', '') = me
     AND coalesce(t.extra->>'lock_intent_note', '') = coalesce(v_note, '')
    THEN RETURN 'unchanged'; END IF;
  UPDATE ledger.ticket
     SET extra = (coalesce(extra, '{}'::jsonb) - 'lock_intent_note')
                 || jsonb_build_object('lock_intent', p_intent, 'lock_intent_by', me)
                 || CASE WHEN v_note IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('lock_intent_note', v_note) END,
         updated_at = now()
   WHERE id = p_id;
  INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
  VALUES (p_id, 'intent', me, jsonb_build_object('was', t.extra->>'lock_intent', 'now', p_intent, 'note', v_note));
  RETURN 'ok';
END $$;


--
-- Name: FUNCTION set_lock_intent(p_id text, p_intent text, p_note text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.set_lock_intent(p_id text, p_intent text, p_note text) IS 'The holder records why a lock is held (building|holding|travelling, travelling with a note) on the row, in the extra keys 045 moved the retired column into. Written for the post-cutover intent verb, whose lock branches carry no ticket file (182).';


--
-- Name: set_remit(text, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.set_remit(p_agent text, p_remit text, p_actor text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $_$
DECLARE v_actor text; v_proof text; v_remit text := nullif(btrim(coalesce(p_remit, '')), '');
BEGIN
  SELECT actor, proof INTO v_actor, v_proof FROM ledger.resolve_actor(p_actor);
  IF NOT EXISTS (SELECT 1 FROM ledger.agent WHERE name = p_agent) THEN RETURN 'no-such-agent'; END IF;
  IF EXISTS (SELECT 1 FROM ledger.agent WHERE name = p_agent AND offboarded IS NOT NULL) THEN RETURN 'agent-offboarded'; END IF;
  IF v_remit IS NOT NULL AND v_remit !~ '^[a-z][a-z0-9-]*$' THEN RETURN 'bad-remit'; END IF;
  UPDATE ledger.agent SET remit = v_remit WHERE name = p_agent;
  INSERT INTO ledger.admin_event(entity, entity_id, verb, actor, actor_proof, detail)
  VALUES ('agent', p_agent, 'remit-set', v_actor, v_proof, jsonb_build_object('remit', v_remit));
  RETURN 'ok';
END $_$;


--
-- Name: set_role(text, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.set_role(p_agent text, p_role text, p_actor text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE v_actor text; v_proof text; v_old text;
BEGIN
  SELECT actor, proof INTO v_actor, v_proof FROM ledger.resolve_actor(p_actor);
  SELECT role INTO v_old FROM ledger.agent WHERE name = p_agent;
  IF NOT FOUND THEN RETURN 'no-such-agent'; END IF;
  IF EXISTS (SELECT 1 FROM ledger.agent WHERE name = p_agent AND offboarded IS NOT NULL) THEN RETURN 'agent-offboarded'; END IF;
  IF NOT EXISTS (SELECT 1 FROM ledger.agent_role WHERE name = p_role) THEN RETURN 'no-such-role'; END IF;
  UPDATE ledger.agent SET role = p_role WHERE name = p_agent;
  INSERT INTO ledger.admin_event(entity, entity_id, verb, actor, actor_proof, detail)
  VALUES ('agent', p_agent, 'role-set', v_actor, v_proof, jsonb_build_object('from', v_old, 'to', p_role));
  RETURN 'ok';
END $$;


--
-- Name: set_status(text, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.set_status(p_id text, p_status text, p_reason text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE
  t ledger.ticket%ROWTYPE;
  me text := session_user;
  v_new ledger.ticket_status;
  v_from_status text := NULL;
BEGIN
  -- ⚠ the reason gate comes FIRST, before any lookup, so a reasonless call cannot have a side
  -- effect of any kind — not even a row lock.
  IF nullif(btrim(coalesce(p_reason,'')),'') IS NULL THEN RETURN 'need-reason'; END IF;

  BEGIN
    v_new := p_status::ledger.ticket_status;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN 'no-such-status:'||coalesce(p_status,'(null)');
  END;

  SELECT * INTO t FROM ledger.ticket WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'no-such-ticket'; END IF;

  -- ⚠ A NO-OP IS REFUSED RATHER THAN RECORDED. This is the defect the mirror has: writing an event
  -- when nothing changed is what buried 499 real transitions under 234,857 repeats. A verb that
  -- records non-changes would reproduce it at a smaller scale, and the smaller scale is exactly
  -- what would make it survive review.
  IF t.status = v_new THEN RETURN 'already:'||v_new::text; END IF;

  -- ⚠ REFUSE IN THE VERB'S OWN VOCABULARY RATHER THAN LEAKING A CONSTRAINT ERROR. `ledger.ticket`
  -- already carries `in_progress_needs_an_owner`, so moving an unowned ticket to in_progress or
  -- parked raises a raw check-constraint violation from inside the UPDATE. Driven 2026-09-01: the
  -- caller got a five-line postgres error naming a constraint and a full row dump, where every
  -- other verb in this schema answers with a short code. A caller cannot branch on that, and the
  -- shell tooling that wraps these verbs reads the return value, not the error stream.
  IF v_new IN ('in_progress','parked') AND t.claimed_by IS NULL AND t.parked_by IS NULL THEN
    RETURN 'needs-an-owner';
  END IF;

  -- ⚠ THE ARCHIVED TRANSITION CARRIES THE TERMINAL OUTCOME WITH IT (migration 168). Until the
  -- ticket files were deleted this column was only ever written by `mirror_ticket`, from a FILE
  -- payload; with no files there was no row-native path to a correct archival at all. The prior
  -- status IS the displaced outcome, and this is the only moment it is known for certain.
  IF v_new = 'archived' THEN
    IF t.status::text NOT IN ('passing','wont_do') THEN
      RETURN 'not-terminal:'||t.status::text;
    END IF;
    v_from_status := t.status::text;
  END IF;

  UPDATE ledger.ticket
     SET status = v_new,
         -- ⚠ COALESCE KEEPS AN EXISTING VALUE rather than overwriting it. A row that already
         -- carries the outcome (every one of the 4,096 mirrored before the cutover) keeps what it
         -- has; this only ever FILLS. An archival that re-derived the column would be a second
         -- opinion about a fact already recorded.
         archived_from_status = coalesce(archived_from_status, v_from_status),
         updated_at = now()
   WHERE id = p_id;

  INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
    VALUES (p_id, 'status', me,
            jsonb_build_object('from', t.status::text, 'to', v_new::text, 'reason', btrim(p_reason)
                               || CASE WHEN v_from_status IS NULL THEN ''
                                       ELSE ' [archived_from_status='||v_from_status||']' END));

  RETURN 'ok';
END $$;


--
-- Name: FUNCTION set_status(p_id text, p_status text, p_reason text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.set_status(p_id text, p_status text, p_reason text) IS 'Moves a ticket between statuses. Since migration 168 the archived transition also records the terminal outcome it displaces, in ledger.ticket.archived_from_status, taken from the row''s own prior status — the only row-native path to a correct archival, and the replacement for archive-passing.sh moving a file that no longer exists. Archiving from a non-terminal status is refused as not-terminal:<status>. Migration 150''s trg_passing_finish_needs_a_pointer still refuses a passing finish with verified_by_pr NULL, and must not be relaxed to make this work.';


--
-- Name: set_ticket_description(text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.set_ticket_description(p_id text, p_body text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE v_actor text := session_user::text; v_held ledger.ticket_status;
BEGIN
  SELECT status INTO v_held FROM ledger.ticket WHERE id = p_id;
  IF v_held IS NULL THEN RETURN 'no-such-ticket'; END IF;

  IF v_held IN ('draft','reviewed') THEN
    -- The database is the only holder. A direct, permanent write -- unchanged from migration 036.
    UPDATE ledger.ticket SET user_visible_behavior = coalesce(p_body,''), updated_at = now() WHERE id = p_id;
    INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
    VALUES (p_id, 'described', v_actor, NULL);
    RETURN 'ok';
  END IF;

  -- ⚠ GIT-BACKED: THE EDIT NOW STANDS, BECAUSE THE OVERRIDE HOLDS IT AGAINST THE NEXT MIRROR.
  -- This is the line migration 036 could not write, and the only reason it could not is that
  -- `user_visible_behavior` was missing from the override's field list.
  RETURN ledger.owner_set_field(p_id, 'user_visible_behavior', coalesce(p_body,''), v_actor);
EXCEPTION WHEN OTHERS THEN RETURN 'refused:' || SQLSTATE || ':' || left(SQLERRM, 120);
END $$;


--
-- Name: FUNCTION set_ticket_description(p_id text, p_body text); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.set_ticket_description(p_id text, p_body text) IS 'Amends a ticket description. A draft/reviewed ticket is database-only and is written directly. A git-backed one goes through ledger.owner_override (migration 136), so the owner''s text holds against the next mirror and retires itself once the exported file carries it. Until 136 this refused git-backed tickets outright, because lifting the refusal without the override would have shipped a silent revert -- see that migration''s header for both arms, driven.';


--
-- Name: stand_down(text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.stand_down(p_id text, p_reason text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE t ledger.ticket%ROWTYPE; me text := session_user;
BEGIN
  IF nullif(btrim(coalesce(p_reason,'')),'') IS NULL THEN RETURN 'need-reason'; END IF;
  SELECT * INTO t FROM ledger.ticket WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'no-such-ticket'; END IF;

  -- ⚠ ACTOR FIRST, AND FROM `session_user`. Same order and same source as release_claim: a caller
  -- who is not an active agent, or not the holder, learns nothing about the ticket's state.
  IF NOT EXISTS (SELECT 1 FROM ledger.agent WHERE name = me AND offboarded IS NULL)
    THEN RETURN 'not-an-active-agent:'||me; END IF;
  IF t.claimed_by IS NULL             THEN RETURN 'already-unassigned'; END IF;
  IF t.claimed_by IS DISTINCT FROM me THEN RETURN 'not-yours:'||t.claimed_by; END IF;

  -- ⚠ ONLY `in_progress`. The verdict NAMES the status so the refusal is actionable -- a bare
  -- `refused` is what sends a reader to the wrong file.
  IF t.status <> 'in_progress' THEN RETURN 'not-in-progress:'||t.status; END IF;

  -- ⚠⚠ `claimed_by` MUST GO TO NULL, NOT JUST THE STATUS. `ledger.v_frontier` requires
  -- `claimed_by IS NULL`, so a row flipped to `selected` with a holder still set is NOT on the
  -- ready frontier and nobody can pick it up. That is exactly how the owner-ruled ticket above sat
  -- unavailable: its status read correct and its frontier membership was false.
  UPDATE ledger.ticket
     SET status = 'selected', claimed_by = NULL, claimed_at = NULL, updated_at = now()
   WHERE id = p_id;

  INSERT INTO ledger.ticket_event(ticket_id,verb,actor,detail)
    VALUES (p_id,'stand-down',me,jsonb_build_object('reason',p_reason,'from','in_progress'));
  RETURN 'ok';
END
$$;


--
-- Name: sync_agent_login_roles(); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.sync_agent_login_roles() RETURNS TABLE(action text, agent text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE a record;
BEGIN
  -- ⚠ THE BODY IS MIGRATION 008'S, MOVED RATHER THAN REWRITTEN. Both halves of the owner's sentence
  -- ("onboarding should create and offboarding remove") are preserved exactly, including that
  -- offboarding is NOLOGIN and never DROP ROLE — `ticket_event.actor` references the agent for ever
  -- and dropping the role would orphan the history that is the point of an append-only ledger.
  FOR a IN SELECT name FROM ledger.agent WHERE offboarded IS NULL LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = a.name) THEN
      EXECUTE format('CREATE ROLE %I LOGIN IN ROLE ledger_agent', a.name);
      action := 'created';  agent := a.name;  RETURN NEXT;
    ELSE
      EXECUTE format('ALTER ROLE %I LOGIN', a.name);
      EXECUTE format('GRANT ledger_agent TO %I', a.name);
      action := 'confirmed'; agent := a.name; RETURN NEXT;
    END IF;
  END LOOP;
  FOR a IN SELECT name FROM ledger.agent WHERE offboarded IS NOT NULL LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = a.name AND rolcanlogin) THEN
      EXECUTE format('ALTER ROLE %I NOLOGIN', a.name);
      action := 'offboarded -> NOLOGIN (history kept)'; agent := a.name; RETURN NEXT;
    END IF;
  END LOOP;
END
$$;


--
-- Name: FUNCTION sync_agent_login_roles(); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.sync_agent_login_roles() IS 'Bring the per-agent login roles into line with ledger.agent. ⚠ RUN THIS AFTER A REBUILD: migration 008 runs during initdb when ledger.agent is EMPTY, so a fresh instance has no agent roles at all and nobody can write to it. Seed the roster first, then call this. It RETURNS what it did, one row per agent, so a caller can tell "created 11" from "created 0" — a function that reports success having done nothing is the failure this replaces.';


--
-- Name: ticket_id_for_head_ref(text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.ticket_id_for_head_ref(ref text) RETURNS text
    LANGUAGE sql STABLE
    AS $_$
  SELECT COALESCE(
    -- 1. the ref WHOLE. Four real tickets end in -pt2; they must win over their own base.
    (SELECT t.id FROM ledger.ticket t WHERE t.id = ref),
    -- 2. only then, the base with a known working suffix removed.
    (SELECT t.id FROM ledger.ticket t
      WHERE t.id = regexp_replace(ref, '-(pt[0-9]+|hotfix|raise|notes|wt|solo|park|rescope)$', '')
        AND ref ~ '-(pt[0-9]+|hotfix|raise|notes|wt|solo|park|rescope)$')
  );
$_$;


--
-- Name: unassign_specialism(text, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.unassign_specialism(p_agent text, p_specialism text, p_actor text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE v_actor text; v_proof text; v_n int; v_existing ledger.evidence; v_may_declare boolean;
BEGIN
  SELECT actor, proof INTO v_actor, v_proof FROM ledger.resolve_actor(p_actor);
  v_may_declare := session_user::text IN ('ledger_owner','ledger_console');

  SELECT evidence INTO v_existing FROM ledger.agent_specialism
   WHERE agent = p_agent AND specialism = p_specialism;
  IF v_existing IS NULL THEN RETURN 'not-held'; END IF;
  IF v_existing = 'declared' AND NOT v_may_declare THEN RETURN 'declared-is-owner-only'; END IF;

  DELETE FROM ledger.agent_specialism WHERE agent = p_agent AND specialism = p_specialism;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN RETURN 'not-held'; END IF;
  INSERT INTO ledger.admin_event(entity, entity_id, verb, actor, actor_proof, detail)
  VALUES ('agent', p_agent, 'specialism-removed', v_actor, v_proof,
          jsonb_build_object('specialism', p_specialism, 'evidence', v_existing));
  RETURN 'ok';
END $$;


--
-- Name: unpark(text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.unpark(p_id text, p_reason text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE t ledger.ticket%ROWTYPE; me text := session_user; v_as_po boolean;
BEGIN
  IF nullif(btrim(coalesce(p_reason,'')),'') IS NULL THEN RETURN 'need-reason'; END IF;
  SELECT * INTO t FROM ledger.ticket WHERE id = p_id FOR UPDATE;
  IF NOT FOUND            THEN RETURN 'no-such-ticket'; END IF;
  -- ⚠ KEYED ON STATUS, NOT ON parked_at — migration 082's measurement, unchanged.
  IF t.status <> 'parked' THEN RETURN 'not-parked'; END IF;

  v_as_po := ledger.park_is_adjudicated_to_the_product_owner(t.status, t.claimed_by, t.adjudicated_from, me);
  IF t.claimed_by IS DISTINCT FROM me AND NOT v_as_po THEN
    RETURN 'not-yours:'||coalesce(t.claimed_by,'(unclaimed)');
  END IF;

  -- ⚠⚠ claimed_by IS SET, AND THE FIRST VERSION OF THIS DID NOT SET IT. Migration 012's
  -- `in_progress_needs_an_owner` refuses `in_progress` with neither claimed_by nor parked_by, and
  -- this statement clears parked_by — so leaving the holder NULL raises rather than producing the
  -- orphan it looks like it produces. See the header: the database refused the design, and it was
  -- right to. `coalesce` makes this a no-op on the ordinary path, where the guard above has already
  -- proved claimed_by = me, and makes the PO the NAMED holder on the carve-out path.
  UPDATE ledger.ticket
     SET status = 'in_progress',
         claimed_by = coalesce(t.claimed_by, me),
         claimed_at = coalesce(t.claimed_at, now()),
         parked_reason = NULL, parked_at = NULL, parked_by = NULL, park_kind = NULL,
         -- The park is gone, so the ask is gone with it. Leaving `waiting_on = owner` behind on an
         -- unparked row would put a ticket nobody is waiting on back onto the owner's queue, and
         -- leaving `ask` behind would leave the trigger's precondition satisfied by a stale string.
         ask = NULL, waiting_on = NULL,
         updated_at = now()
   WHERE id = p_id;
  INSERT INTO ledger.ticket_event(ticket_id,verb,actor,detail)
    VALUES (p_id,'unpark',me,jsonb_build_object(
      'reason',p_reason,'as_product_owner',v_as_po,'adjudicated_from',t.adjudicated_from));
  RETURN 'ok';
END $$;


--
-- Name: unretire_ticket(text, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.unretire_ticket(p_id text, p_reason text, p_actor text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
DECLARE
  v_actor text; v_proof text; v_retired timestamptz; v_was text;
  v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
BEGIN
  SELECT actor, proof INTO v_actor, v_proof FROM ledger.resolve_actor(p_actor);
  IF v_actor IS NULL THEN RETURN 'refused:no-actor'; END IF;
  IF v_reason IS NULL THEN RETURN 'refused:no-reason'; END IF;

  SELECT retired_at, retired_reason INTO v_retired, v_was FROM ledger.ticket WHERE id = p_id;
  IF NOT FOUND THEN RETURN 'refused:no-such-ticket'; END IF;
  IF v_retired IS NULL THEN RETURN 'not-retired'; END IF;

  UPDATE ledger.ticket
     SET retired_at = NULL, retired_by = NULL, retired_reason = NULL, updated_at = now()
   WHERE id = p_id;

  INSERT INTO ledger.ticket_event(ticket_id, verb, actor, detail)
  VALUES (p_id, 'unretired', v_actor,
          jsonb_build_object('proof', v_proof, 'reason', v_reason, 'was_retired_because', v_was));
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN 'refused:'||SQLSTATE||':'||left(SQLERRM,120);
END $$;


--
-- Name: updated_at_only_on_a_real_change(); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.updated_at_only_on_a_real_change() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
BEGIN
  IF (to_jsonb(NEW) - 'updated_at') IS NOT DISTINCT FROM (to_jsonb(OLD) - 'updated_at') THEN
    NEW.updated_at := OLD.updated_at;
  END IF;
  RETURN NEW;
END $$;


--
-- Name: upsert_specialism(text, text, text, text, text); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.upsert_specialism(p_name text, p_axis text, p_area text, p_description text, p_actor text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $_$
DECLARE v_actor text; v_proof text; v_existed boolean;
BEGIN
  SELECT actor, proof INTO v_actor, v_proof FROM ledger.resolve_actor(p_actor);
  p_name := lower(trim(coalesce(p_name,'')));
  IF p_name !~ '^[a-z][a-z0-9-]{1,40}$' THEN RETURN 'bad-name'; END IF;
  IF p_axis NOT IN ('area','discipline')  THEN RETURN 'bad-axis'; END IF;
  -- ⚠ An 'area' specialism must name a real area, and a 'discipline' must name none. The CHECK
  -- above enforces the shape; this enforces that the area actually exists.
  IF p_axis = 'area' THEN
    IF NOT EXISTS (SELECT 1 FROM ledger.area WHERE name = p_area) THEN RETURN 'no-such-area'; END IF;
  ELSE
    p_area := NULL;
  END IF;

  SELECT EXISTS(SELECT 1 FROM ledger.specialism WHERE name = p_name) INTO v_existed;
  INSERT INTO ledger.specialism(name, axis, area, description)
  VALUES (p_name, p_axis, p_area, coalesce(p_description,''))
  ON CONFLICT (name) DO UPDATE SET
    axis = EXCLUDED.axis, area = EXCLUDED.area,
    description = EXCLUDED.description, retired_at = NULL;

  INSERT INTO ledger.admin_event(entity, entity_id, verb, actor, actor_proof, detail)
  VALUES ('specialism', p_name, CASE WHEN v_existed THEN 'updated' ELSE 'created' END,
          v_actor, v_proof, jsonb_build_object('axis', p_axis, 'area', p_area));
  RETURN CASE WHEN v_existed THEN 'updated' ELSE 'created' END;
END $_$;


--
-- Name: waiting_on_owner_requires_an_ask(); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.waiting_on_owner_requires_an_ask() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'ledger', 'pg_temp'
    AS $$
BEGIN
  -- Not waiting on the owner: nothing to say.
  IF NEW.waiting_on IS DISTINCT FROM 'owner' THEN RETURN NEW; END IF;

  -- ⚠ AN EMPTY STRING IS NOT AN ASK. `NOT NULL` alone would be satisfied by '' and by three spaces,
  -- and a queue row rendering blank is worse than one that says it has none: the blank reads as an
  -- ask somebody wrote badly, rather than as one nobody wrote.
  IF nullif(btrim(coalesce(NEW.ask,'')),'') IS NOT NULL THEN RETURN NEW; END IF;

  -- ⚠ THE LEGACY CLAUSE, AND IT IS WHY THIS IS A TRIGGER. A row ALREADY in (owner, no ask) may
  -- still be updated — otherwise the next mirror pass over those two rows fails and the ticket
  -- freezes. Note what this does NOT permit: if OLD carried an ask, stripping it is refused, so the
  -- exemption cannot be used to reach the bad state from a good one.
  IF TG_OP = 'UPDATE'
     AND OLD.waiting_on IS NOT DISTINCT FROM 'owner'
     AND nullif(btrim(coalesce(OLD.ask,'')),'') IS NULL
  THEN RETURN NEW;
  END IF;

  RAISE EXCEPTION USING
    ERRCODE = 'check_violation',
    MESSAGE = format('waiting_on = owner requires an ask (ticket %s)', coalesce(NEW.id,'?')),
    DETAIL  = 'Spec §2: the owner queue shows the ask, and a row cannot enter it without one.',
    HINT    = 'Say in one line what the owner must DO, not what is blocking it: '
              'bash scripts/feature-ticket.sh park <id> --kind=blocked_on_owner --summary="<the ask>"';
END $$;


--
-- Name: FUNCTION waiting_on_owner_requires_an_ask(); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.waiting_on_owner_requires_an_ask() IS 'Spec §2, enforced on the TRANSITION rather than the state, so the rows that lack an ask today stay updatable instead of freezing. Created after migration 112 backfills, or it would trip on its own backfill.';


--
-- Name: write_session_entry(jsonb); Type: FUNCTION; Schema: ledger; Owner: -
--

CREATE FUNCTION ledger.write_session_entry(p jsonb) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'ledger', 'pg_temp'
    AS $_$
DECLARE me text := session_user;
        v_title  text := nullif(btrim(coalesce(p->>'title',  '')), '');
        v_body   text := nullif(btrim(coalesce(p->>'body',   '')), '');
        v_ticket text := nullif(btrim(coalesce(p->>'ticket_id', '')), '');
        v_branch text := nullif(btrim(coalesce(p->>'branch', '')), '');
        v_pr_raw text := nullif(btrim(coalesce(p->>'pr', '')), '');
        v_pr     integer;
        v_id     bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ledger.agent WHERE name = me AND offboarded IS NULL)
    THEN RETURN 'not-an-active-agent:' || me; END IF;
  IF v_title IS NULL THEN RETURN 'needs-a-title'; END IF;
  IF v_body  IS NULL THEN RETURN 'empty-body'; END IF;
  IF v_ticket IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ledger.ticket WHERE id = v_ticket)
    THEN RETURN 'no-such-ticket:' || v_ticket; END IF;
  IF v_pr_raw IS NOT NULL THEN
    IF v_pr_raw !~ '^[0-9]{1,9}$' OR v_pr_raw::integer = 0 THEN RETURN 'bad-pr:' || v_pr_raw; END IF;
    v_pr := v_pr_raw::integer;
  END IF;
  INSERT INTO ledger.session_entry(agent, ticket_id, branch, pr, title, body)
  VALUES (me, v_ticket, v_branch, v_pr, v_title, v_body)
  RETURNING id INTO v_id;
  RETURN 'ok:' || v_id;
END $_$;


--
-- Name: FUNCTION write_session_entry(p jsonb); Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON FUNCTION ledger.write_session_entry(p jsonb) IS 'Records a session entry as the calling agent (session_user). Refuses a non-agent, an empty title or body, an unknown ticket, and a malformed PR number; returns ok:<id> (190).';


SET default_tablespace = '';


--
-- Name: admin_event; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.admin_event (
    seq bigint NOT NULL,
    entity text NOT NULL,
    entity_id text NOT NULL,
    verb text NOT NULL,
    actor text NOT NULL,
    actor_proof text NOT NULL,
    detail jsonb DEFAULT '{}'::jsonb NOT NULL,
    at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_event_actor_proof_check CHECK ((actor_proof = ANY (ARRAY['connection'::text, 'console-asserted'::text])))
);


--
-- Name: admin_event_seq_seq; Type: SEQUENCE; Schema: ledger; Owner: -
--

CREATE SEQUENCE ledger.admin_event_seq_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: admin_event_seq_seq; Type: SEQUENCE OWNED BY; Schema: ledger; Owner: -
--

ALTER SEQUENCE ledger.admin_event_seq_seq OWNED BY ledger.admin_event.seq;


--
-- Name: agent; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.agent (
    name text NOT NULL,
    email text NOT NULL,
    role text NOT NULL,
    onboarded date NOT NULL,
    offboarded date,
    remit text,
    CONSTRAINT agent_name_check CHECK ((name ~ '^[A-Za-z][A-Za-z0-9_-]{1,31}$'::text)),
    CONSTRAINT left_after_joining CHECK (((offboarded IS NULL) OR (offboarded >= onboarded)))
);


--
-- Name: COLUMN agent.remit; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.agent.remit IS 'A standing responsibility on top of the role, naming docs/roles/<remit>.md — mirrors agents/roster.json remit (migration 130).';


--
-- Name: agent_role; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.agent_role (
    name text NOT NULL
);


--
-- Name: agent_specialism; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.agent_specialism (
    agent text NOT NULL,
    specialism text NOT NULL,
    depth ledger.depth NOT NULL,
    declared_by text NOT NULL,
    declared_at timestamp with time zone DEFAULT now() NOT NULL,
    note text,
    evidence ledger.evidence DEFAULT 'inferred'::ledger.evidence NOT NULL
);


--
-- Name: COLUMN agent_specialism.evidence; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.agent_specialism.evidence IS 'How we know. declared = the owner said so. inferred = an agent recorded it from behaviour. An inferred row is probably right and is NOT evidence. Only the owner promotes inferred to declared.';


--
-- Name: area; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.area (
    name text NOT NULL,
    layer text NOT NULL,
    description text NOT NULL,
    legacy boolean DEFAULT false NOT NULL,
    retired_at timestamp with time zone
);


--
-- Name: area_synonym; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.area_synonym (
    alias text NOT NULL,
    area text NOT NULL
);


--
-- Name: comment; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.comment (
    seq bigint NOT NULL,
    ticket_id text NOT NULL,
    body text NOT NULL,
    author text NOT NULL,
    author_kind text NOT NULL,
    at timestamp with time zone DEFAULT now() NOT NULL,
    reviewed_at timestamp with time zone,
    reviewed_by text,
    CONSTRAINT comment_author_kind_check CHECK ((author_kind = ANY (ARRAY['owner'::text, 'agent'::text]))),
    CONSTRAINT comment_body_not_blank CHECK ((btrim(body) <> ''::text)),
    CONSTRAINT review_is_whole CHECK (((reviewed_at IS NULL) = (reviewed_by IS NULL)))
);


--
-- Name: TABLE comment; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON TABLE ledger.comment IS 'A ticket''s comment thread. NOT ledger.ticket_event, because that table is append-only by trigger and marking a comment reviewed is an UPDATE. Only the review columns may change here; body, author, author_kind and at are fixed once written, and DELETE is refused. `unreviewed` is DERIVED (author_kind = owner AND reviewed_at IS NULL) and has no writer.';


--
-- Name: comment_seq_seq; Type: SEQUENCE; Schema: ledger; Owner: -
--

CREATE SEQUENCE ledger.comment_seq_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: comment_seq_seq; Type: SEQUENCE OWNED BY; Schema: ledger; Owner: -
--

ALTER SEQUENCE ledger.comment_seq_seq OWNED BY ledger.comment.seq;


--
-- Name: github_poll; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.github_poll (
    id boolean DEFAULT true NOT NULL,
    last_attempt_at timestamp with time zone,
    last_ok_at timestamp with time zone,
    last_error text,
    rate_remaining integer,
    rate_reset_at timestamp with time zone,
    prs_seen integer,
    prs_unmapped integer,
    CONSTRAINT github_poll_id_check CHECK (id)
);


--
-- Name: import_drift; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.import_drift (
    seq bigint NOT NULL,
    entity text NOT NULL,
    id text NOT NULL,
    field text NOT NULL,
    found text,
    note text NOT NULL,
    at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: import_drift_seq_seq; Type: SEQUENCE; Schema: ledger; Owner: -
--

CREATE SEQUENCE ledger.import_drift_seq_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: import_drift_seq_seq; Type: SEQUENCE OWNED BY; Schema: ledger; Owner: -
--

ALTER SEQUENCE ledger.import_drift_seq_seq OWNED BY ledger.import_drift.seq;


--
-- Name: owner_override; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.owner_override (
    ticket_id text NOT NULL,
    field text NOT NULL,
    value text NOT NULL,
    set_by text NOT NULL,
    set_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT owner_override_field_check CHECK ((field = ANY (ARRAY['priority'::text, 'area'::text, 'status'::text, 'title'::text, 'user_visible_behavior'::text, 'notes'::text, 'verification'::text, 'verification_command'::text])))
);


--
-- Name: TABLE owner_override; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON TABLE ledger.owner_override IS 'Fields the owner has set from /ledger that git does not yet carry. A row here means the DATABASE owns that field until git catches up, at which point the row retires itself. Empty is the normal steady state -- a growing table means export/commit has stopped, not that the owner is busy. Covers the four grooming fields (priority, area, status, title) and, since migration 136, the four REQUIREMENT fields (user_visible_behavior, notes, verification, verification_command). The agent lifecycle columns are deliberately absent -- see migration 025.';


--
-- Name: pr; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.pr (
    number integer NOT NULL,
    ticket_id text NOT NULL,
    state text NOT NULL,
    head_ref text NOT NULL,
    title text NOT NULL,
    url text NOT NULL,
    opened_at timestamp with time zone,
    merged_at timestamp with time zone,
    closed_at timestamp with time zone,
    check_state text,
    check_updated_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT merged_has_a_time CHECK (((state = 'merged'::text) = (merged_at IS NOT NULL))),
    CONSTRAINT pr_check_state_check CHECK (((check_state IS NULL) OR (check_state = ANY (ARRAY['success'::text, 'failure'::text, 'pending'::text, 'cancelled'::text, 'skipped'::text, 'neutral'::text, 'timed_out'::text])))),
    CONSTRAINT pr_state_check CHECK ((state = ANY (ARRAY['open'::text, 'closed'::text, 'merged'::text])))
);


--
-- Name: request; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.request (
    seq bigint NOT NULL,
    raw text NOT NULL,
    note text,
    raised_by text NOT NULL,
    raised_at timestamp with time zone DEFAULT now() NOT NULL,
    ticket_id text,
    dismissed_reason text,
    dismissed_at timestamp with time zone,
    dismissed_by text,
    CONSTRAINT request_dismissal_needs_a_reason CHECK ((((dismissed_at IS NULL) AND (dismissed_reason IS NULL) AND (dismissed_by IS NULL)) OR ((dismissed_at IS NOT NULL) AND (btrim(COALESCE(dismissed_reason, ''::text)) <> ''::text) AND (dismissed_by IS NOT NULL)))),
    CONSTRAINT request_raw_not_blank CHECK ((btrim(raw) <> ''::text)),
    CONSTRAINT request_ticketed_xor_dismissed CHECK ((NOT ((ticket_id IS NOT NULL) AND (dismissed_at IS NOT NULL))))
);


--
-- Name: TABLE request; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON TABLE ledger.request IS 'Work items as the owner wrote them. A row is OUTSTANDING until it is linked to a ticket or dismissed with a reason. The point is the denominator: "seven raised, five ticketed, two outstanding" is a query, not a memory.';


--
-- Name: request_seq_seq; Type: SEQUENCE; Schema: ledger; Owner: -
--

CREATE SEQUENCE ledger.request_seq_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: request_seq_seq; Type: SEQUENCE OWNED BY; Schema: ledger; Owner: -
--

ALTER SEQUENCE ledger.request_seq_seq OWNED BY ledger.request.seq;


--
-- Name: schema_migration; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.schema_migration (
    filename text NOT NULL,
    applied_at timestamp with time zone,
    applied_by text,
    checksum text,
    note text,
    CONSTRAINT applied_at_and_by_together CHECK (((applied_at IS NULL) = (applied_by IS NULL)))
);


--
-- Name: TABLE schema_migration; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON TABLE ledger.schema_migration IS 'Which files in infra/ledger-db/ have been applied to THIS instance. applied_at NULL = predates this table, unverified. Written in the same transaction as the DDL by scripts/ledger-migrate.sh.';


--
-- Name: session_entry; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.session_entry (
    id bigint NOT NULL,
    agent text NOT NULL,
    written_at timestamp with time zone DEFAULT now() NOT NULL,
    ticket_id text,
    branch text,
    pr integer,
    title text NOT NULL,
    body text NOT NULL,
    CONSTRAINT session_entry_body_check CHECK ((btrim(body) <> ''::text)),
    CONSTRAINT session_entry_pr_check CHECK (((pr IS NULL) OR (pr > 0))),
    CONSTRAINT session_entry_title_check CHECK ((btrim(title) <> ''::text))
);


--
-- Name: TABLE session_entry; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON TABLE ledger.session_entry IS 'One row per session entry (CLAUDE.md step 4). Written only by ledger.write_session_entry, which takes the author from session_user. progress/ is the frozen history from before this table (190).';


--
-- Name: session_entry_id_seq; Type: SEQUENCE; Schema: ledger; Owner: -
--

CREATE SEQUENCE ledger.session_entry_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: session_entry_id_seq; Type: SEQUENCE OWNED BY; Schema: ledger; Owner: -
--

ALTER SEQUENCE ledger.session_entry_id_seq OWNED BY ledger.session_entry.id;


--
-- Name: specialism; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.specialism (
    name text NOT NULL,
    axis text NOT NULL,
    area text,
    retired_at timestamp with time zone,
    description text DEFAULT ''::text NOT NULL,
    CONSTRAINT area_axis_is_backed CHECK (((axis = 'area'::text) = (area IS NOT NULL))),
    CONSTRAINT specialism_area_iff_area_axis CHECK (((axis = 'area'::text) = (area IS NOT NULL))),
    CONSTRAINT specialism_axis_check CHECK ((axis = ANY (ARRAY['area'::text, 'discipline'::text])))
);


--
-- Name: sync_run; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.sync_run (
    seq bigint NOT NULL,
    at timestamp with time zone DEFAULT now() NOT NULL,
    actor text DEFAULT SESSION_USER NOT NULL,
    mode text NOT NULL,
    head_sha text,
    n_seen integer NOT NULL,
    n_mirrored integer NOT NULL,
    n_refused integer NOT NULL,
    CONSTRAINT sync_run_mode_check CHECK ((mode = ANY (ARRAY['main'::text, 'worktree'::text]))),
    CONSTRAINT sync_run_n_mirrored_check CHECK ((n_mirrored >= 0)),
    CONSTRAINT sync_run_n_refused_check CHECK ((n_refused >= 0)),
    CONSTRAINT sync_run_n_seen_check CHECK ((n_seen >= 0))
);


--
-- Name: TABLE sync_run; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON TABLE ledger.sync_run IS 'One row per ledger-db.sh sync. Answers "when was this board last read from origin/main, by which role, at which commit" -- a question no other table can answer: ticket_event.verb=''mirrored'' also fires for single-ticket writes, and the --since-last marker is a local file on one agent''s disk. Freshness is a property of the board, so it lives in the board.';


--
-- Name: COLUMN sync_run.actor; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.sync_run.actor IS 'session_user -- a Postgres ROLE, never a roster name. Answers "who ran the sync", never "whose work is this". Same domain as schema_migration.applied_by (#7192).';


--
-- Name: COLUMN sync_run.mode; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.sync_run.mode IS '''main'' = read of origin/main, the only mode that freshens the board. ''worktree'' = one agent''s proposal, recorded for honesty and excluded from v_board_freshness.';


--
-- Name: sync_run_seq_seq; Type: SEQUENCE; Schema: ledger; Owner: -
--

CREATE SEQUENCE ledger.sync_run_seq_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sync_run_seq_seq; Type: SEQUENCE OWNED BY; Schema: ledger; Owner: -
--

ALTER SEQUENCE ledger.sync_run_seq_seq OWNED BY ledger.sync_run.seq;


--
-- Name: ticket; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.ticket (
    id text NOT NULL,
    title text NOT NULL,
    area text NOT NULL,
    status ledger.ticket_status DEFAULT 'not_started'::ledger.ticket_status NOT NULL,
    priority smallint DEFAULT 3 NOT NULL,
    user_visible_behavior text DEFAULT ''::text NOT NULL,
    notes text DEFAULT ''::text NOT NULL,
    verification text[] DEFAULT '{}'::text[] NOT NULL,
    verification_command text,
    parent text,
    depends_on text[] DEFAULT '{}'::text[] NOT NULL,
    solo boolean DEFAULT false NOT NULL,
    claimed_by text,
    claimed_at timestamp with time zone,
    parked_reason text,
    parked_at timestamp with time zone,
    parked_by text,
    raised_by text,
    verified_by_pr integer,
    issue integer,
    extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    mirror_refused_at timestamp with time zone,
    mirror_refused_reason text,
    park_kind ledger.park_kind,
    park_summary text,
    park_condition text,
    adjudicated_by text,
    adjudicated_at timestamp with time zone,
    adjudicated_from text,
    waiting_on text,
    ask text,
    claimed_by_carried boolean,
    retired_at timestamp with time zone,
    retired_by text,
    retired_reason text,
    legacy_source text,
    archived_from_status text,
    evidence text,
    acceptance text[] DEFAULT '{}'::text[] NOT NULL,
    last_verified_commit text,
    delivered_by text,
    ref integer NOT NULL,
    CONSTRAINT acceptance_is_an_array CHECK ((((extra -> 'acceptance'::text) IS NULL) OR (jsonb_typeof((extra -> 'acceptance'::text)) = 'array'::text))),
    CONSTRAINT blocked_on_is_an_array CHECK ((((extra -> 'blocked_on'::text) IS NULL) OR (jsonb_typeof((extra -> 'blocked_on'::text)) = 'array'::text))),
    CONSTRAINT evidence_is_a_string CHECK ((((extra -> 'evidence'::text) IS NULL) OR (jsonb_typeof((extra -> 'evidence'::text)) = 'string'::text))),
    CONSTRAINT in_progress_needs_an_owner CHECK (((status <> ALL (ARRAY['in_progress'::ledger.ticket_status, 'parked'::ledger.ticket_status])) OR (claimed_by IS NOT NULL) OR (parked_by IS NOT NULL))),
    CONSTRAINT park_columns_are_clear_when_not_parked CHECK (((status = 'parked'::ledger.ticket_status) OR ((parked_reason IS NULL) AND (parked_at IS NULL) AND (parked_by IS NULL) AND (park_kind IS NULL)))),
    CONSTRAINT parked_needs_a_reason CHECK ((((parked_at IS NULL) AND (status <> 'parked'::ledger.ticket_status)) OR ((NULLIF(btrim(parked_reason), ''::text) IS NOT NULL) AND (parked_at IS NOT NULL)))),
    CONSTRAINT retire_columns_travel_together CHECK ((((retired_at IS NULL) AND (retired_by IS NULL) AND (retired_reason IS NULL)) OR ((retired_at IS NOT NULL) AND (retired_by IS NOT NULL) AND (btrim(COALESCE(retired_reason, ''::text)) <> ''::text)))),
    CONSTRAINT scope_is_an_array CHECK ((((extra -> 'scope'::text) IS NULL) OR (jsonb_typeof((extra -> 'scope'::text)) = 'array'::text))),
    CONSTRAINT ticket_archived_from_status_check CHECK (((archived_from_status IS NULL) OR (archived_from_status = ANY (ARRAY['passing'::text, 'wont_do'::text])))),
    CONSTRAINT ticket_id_check CHECK ((id ~ '^[a-z][a-z0-9_-]{4,200}$'::text)),
    CONSTRAINT ticket_priority_check CHECK (((priority >= 1) AND (priority <= 5))),
    CONSTRAINT ticket_title_check CHECK (((length(title) >= 8) AND (length(title) <= 600))),
    CONSTRAINT waiting_on_is_one_of_three CHECK (((waiting_on IS NULL) OR (waiting_on = ANY (ARRAY['owner'::text, 'other'::text]))))
);


--
-- Name: COLUMN ticket.mirror_refused_at; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.ticket.mirror_refused_at IS 'Set when a mirror of this ticket was REFUSED, so the row is not known to agree with origin/main. Cleared by the next successful mirror. v_frontier excludes rows carrying it.';


--
-- Name: COLUMN ticket.park_kind; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.ticket.park_kind IS 'What KIND of park this is, modelled rather than inferred from prose. blocked_on_owner = waiting on the owner (this is what v_owner_blocked selects). blocked_on_other = waiting on a dependency, a box, an occurrence or another agent -- a real block that is NOT his. banked = finished-but-unlanded work the owner of the ticket is deliberately holding; nobody is waiting on anybody. NULL means not parked. Set by ledger.park. See migration 33.';


--
-- Name: COLUMN ticket.park_summary; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.ticket.park_summary IS 'One or two plain-English sentences naming what is blocking this ticket and what would clear it, for a reader who does not work on this repo. NULLABLE BY CONSTRUCTION: the ~68 tickets parked before this migration keep their detail and are not back-filled — a generated summary of a park reason is a paraphrase of the one field that must not be paraphrased. The rule applies forward.';


--
-- Name: COLUMN ticket.park_condition; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.ticket.park_condition IS 'What would have to become true for this park to clear, as a runnable read-only check (`bash scripts/<file> [verb]`), or `none: <why nothing can check this>`. NULL means nobody has said — which is what migration 101 exists to stop on new parks. Shape only: this cannot tell a check that reads the authoritative copy from one that does not.';


--
-- Name: COLUMN ticket.adjudicated_from; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.ticket.adjudicated_from IS 'The retired holder this ticket was taken from. Kept because parked_by stays the original AUTHOR of the park; this records who was RELIEVED of it, which is a different fact.';


--
-- Name: COLUMN ticket.waiting_on; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.ticket.waiting_on IS 'Spec §2. Who or what this ticket is waiting for: owner, other, or null. Not a status — the same status with a reason attached. Backfilled from park_kind by migration 112.';


--
-- Name: COLUMN ticket.ask; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.ticket.ask IS 'Spec §2. One line saying what the OWNER must DO, for a reader who does not work on this repo. Required when waiting_on = owner — enforced by trg_waiting_on_owner_requires_an_ask, on the TRANSITION. The long version stays in parked_reason, which the owner queue does not show.';


--
-- Name: COLUMN ticket.claimed_by_carried; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.ticket.claimed_by_carried IS 'Did the payload that last set claimed_by CARRY the key? THREE STATES, and they are not two. true  = a payload carried it (a name, or an explicit null meaning hand-back). false = a payload was mirrored and did NOT carry it — a positive fact, recorded on INSERT. NULL  = no payload has told us; the row predates this column. Reconstruction omits the key for BOTH false and NULL, so this migration changes no output on its own. ⚠ An absent key on UPDATE PRESERVES the flag rather than writing false, exactly as it preserves claimed_by, because absent means "git did not mention ownership" and must not overwrite what a payload that DID mention it recorded. So false is reachable on insert and never by overwrite. Driven 2026-09-10, all four arms.';


--
-- Name: COLUMN ticket.retired_at; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.ticket.retired_at IS 'Set when a ticket is withdrawn from the board without being delivered or declined. NOT a status: the row keeps the status it held, so "in_progress when withdrawn" stays distinguishable from "not_started when withdrawn". Excluded from the board and frontier views; deliberately still visible in the lookup views (v_ticket, v_ticket_detail) per migration 060''s PO ruling — a row you cannot look up is worse than one on a list. Reversible via ledger.unretire_ticket.';


--
-- Name: COLUMN ticket.legacy_source; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.ticket.legacy_source IS 'NULL for a ticket that went through the current lifecycle. Non-NULL names the legacy store a row was imported from (today only feature_list.archive.jsonl). Set ONLY by ledger.import_legacy_ticket.';


--
-- Name: COLUMN ticket.archived_from_status; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.ticket.archived_from_status IS 'The terminal outcome that status=''archived'' displaces: passing or wont_do. NULL for every ticket that is not archived, and for an archived ticket whose outcome could not be recovered. Written by ledger.mirror_ticket from the payload key of the same name. ⚠ Do NOT coalesce this with status when reading: a NULL here means UNKNOWN, and ledger-db.sh --write drops nulls so an unrecoverable ticket is left alone rather than being told it passed.';


--
-- Name: COLUMN ticket.evidence; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.ticket.evidence IS 'What was driven to show the ticket is done, in the author''s own words. Requirement field: the DATABASE owns it (migration 140), so a file''s value is not applied to an existing row — a disagreement is recorded in import_drift instead.';


--
-- Name: COLUMN ticket.acceptance; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.ticket.acceptance IS 'The ticket''s acceptance criteria, one per element. text[] because it is an array on every file that has one (260 of 260 measured) — flattening would destroy the boundaries, which is the defect `notes` already carries.';


--
-- Name: COLUMN ticket.last_verified_commit; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.ticket.last_verified_commit IS '⚠ LEGACY. The branch commit a ticket was verified at, before verified_by_pr replaced it (2026-08-18). INVALID ON MAIN BY CONSTRUCTION — every merge method rewrites the commit it names, and 1,106 of 1,246 stamps do not exist there. Keep what is recorded; never require it, never re-stamp it, and never read a live-looking sha here as evidence of anything.';


--
-- Name: COLUMN ticket.delivered_by; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.ticket.delivered_by IS 'Who flipped this ticket to passing, written by ledger.flip_passing from session_user in the same UPDATE that clears claimed_by. NULL means UNKNOWN (pre-2026-08-26 deliveries have no event trace and are deliberately not backfilled) — it never means unowned.';


--
-- Name: COLUMN ticket.ref; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON COLUMN ledger.ticket.ref IS 'A short, permanent, never-reused address for this ticket -- what a person says out loud instead of the id. ⚠ IT IS AN ADDRESS, NOT A CHRONOLOGY: a low ref does not mean an old ticket, because the backfill ordered by created_at and that is the ROW IMPORT time for the ~3,740 rows brought in on 2026-08-26 and 2026-09-15. Never sort by it as a proxy for age and never render it as one; the date columns from migration 169 answer "when". Assigned by DEFAULT from ledger.ticket_ref_seq so every insert path gets one and no procedure supplies it.';


--
-- Name: ticket_event; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.ticket_event (
    seq bigint NOT NULL,
    ticket_id text NOT NULL,
    verb text NOT NULL,
    actor text NOT NULL,
    detail jsonb,
    at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT status_event_needs_a_reason CHECK (((verb <> 'status'::text) OR ((NULLIF(btrim(COALESCE((detail ->> 'reason'::text), ''::text)), ''::text) IS NOT NULL) AND (NULLIF(btrim(COALESCE((detail ->> 'to'::text), ''::text)), ''::text) IS NOT NULL))))
);


--
-- Name: ticket_event_seq_seq; Type: SEQUENCE; Schema: ledger; Owner: -
--

CREATE SEQUENCE ledger.ticket_event_seq_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ticket_event_seq_seq; Type: SEQUENCE OWNED BY; Schema: ledger; Owner: -
--

ALTER SEQUENCE ledger.ticket_event_seq_seq OWNED BY ledger.ticket_event.seq;


--
-- Name: ticket_pr; Type: TABLE; Schema: ledger; Owner: -
--

CREATE TABLE ledger.ticket_pr (
    ticket_id text NOT NULL,
    pr_number integer NOT NULL,
    title text,
    state text,
    merged_at timestamp with time zone,
    directive text NOT NULL,
    collected_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE ticket_pr; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON TABLE ledger.ticket_pr IS 'Every PR whose body carries a linking directive for a ticket''s issue. Collected from GitHub; a bare mention of the issue number is deliberately NOT a row (measured 3x overcount on #6193).';


--
-- Name: ticket_ref_seq; Type: SEQUENCE; Schema: ledger; Owner: -
--

CREATE SEQUENCE ledger.ticket_ref_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ticket_ref_seq; Type: SEQUENCE OWNED BY; Schema: ledger; Owner: -
--

ALTER SEQUENCE ledger.ticket_ref_seq OWNED BY ledger.ticket.ref;


--
-- Name: v_admin_history; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_admin_history AS
 SELECT seq,
    entity,
    entity_id,
    verb,
    actor,
    actor_proof,
    detail,
    at
   FROM ledger.admin_event
  ORDER BY seq DESC;


--
-- Name: v_agent; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_agent AS
 SELECT name,
    email,
    role,
    onboarded,
    offboarded,
    (offboarded IS NULL) AS active,
    (COALESCE(offboarded, CURRENT_DATE) - onboarded) AS days_with_us
   FROM ledger.agent;


--
-- Name: v_agent_demonstrated; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_agent_demonstrated AS
 SELECT e.actor AS agent,
    t.area,
    count(*) AS delivered,
    max(e.at) AS most_recent
   FROM (ledger.ticket_event e
     JOIN ledger.ticket t ON ((t.id = e.ticket_id)))
  WHERE (e.verb = 'flip_passing'::text)
  GROUP BY e.actor, t.area;


--
-- Name: v_agent_profile; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_agent_profile AS
 SELECT name,
    role,
    email,
    onboarded,
    offboarded,
    (offboarded IS NULL) AS active,
        CASE
            WHEN (onboarded IS NULL) THEN NULL::integer
            ELSE ((COALESCE((offboarded)::timestamp with time zone, now()))::date - onboarded)
        END AS days_with_us,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('name', x.specialism, 'depth', x.depth, 'axis', s.axis, 'note', x.note, 'evidence', x.evidence) ORDER BY x.depth, x.specialism) AS jsonb_agg
           FROM (ledger.agent_specialism x
             JOIN ledger.specialism s ON ((s.name = x.specialism)))
          WHERE (x.agent = a.name)), '[]'::jsonb) AS declared,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('area', d.area, 'delivered', d.delivered) ORDER BY d.delivered DESC) AS jsonb_agg
           FROM ledger.v_agent_demonstrated d
          WHERE (d.agent = a.name)), '[]'::jsonb) AS demonstrated,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('area', h.area, 'holding', h.n) ORDER BY h.n DESC) AS jsonb_agg
           FROM ( SELECT t.area,
                    count(*) AS n
                   FROM ledger.ticket t
                  WHERE ((t.claimed_by = a.name) AND (t.status = ANY (ARRAY['in_progress'::ledger.ticket_status, 'parked'::ledger.ticket_status])) AND (NOT ledger.is_probe(t.id)))
                  GROUP BY t.area) h), '[]'::jsonb) AS holding,
    remit
   FROM ledger.agent a;


--
-- Name: v_board_freshness; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_board_freshness AS
 SELECT (( SELECT count(*) AS count
           FROM ledger.sync_run
          WHERE (sync_run.mode = 'main'::text)) = 0) AS never_synced,
    r.at AS last_main_sync_at,
        CASE
            WHEN (r.at IS NULL) THEN NULL::bigint
            ELSE (EXTRACT(epoch FROM (now() - r.at)))::bigint
        END AS age_seconds,
    r.actor AS last_main_sync_by,
    r.head_sha AS last_main_sync_sha,
    r.n_seen,
    r.n_mirrored,
    r.n_refused
   FROM (( SELECT 1 AS "?column?") _always_one_row
     LEFT JOIN LATERAL ( SELECT sync_run.at,
            sync_run.actor,
            sync_run.head_sha,
            sync_run.n_seen,
            sync_run.n_mirrored,
            sync_run.n_refused
           FROM ledger.sync_run
          WHERE (sync_run.mode = 'main'::text)
          ORDER BY sync_run.at DESC
         LIMIT 1) r ON (true));


--
-- Name: VIEW v_board_freshness; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON VIEW ledger.v_board_freshness IS 'Always exactly one row. never_synced says so in words rather than by returning nothing -- an empty result and a clean result are indistinguishable to a caller, and empty reads as fine. Reports the measurement (age, sha, counts); the fresh/stale THRESHOLD is policy and lives in scripts/ledger-db.sh freshness_verdict, which has a self-test.';


--
-- Name: v_claims; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_claims AS
 SELECT id,
    title,
    area,
    status,
    claimed_by,
    claimed_at,
    (parked_at IS NOT NULL) AS parked,
    parked_reason,
    ((status <> ALL (ARRAY['in_progress'::ledger.ticket_status, 'parked'::ledger.ticket_status])) AND (claimed_by IS NOT NULL)) AS held,
    (EXTRACT(epoch FROM (now() - claimed_at)))::bigint AS held_s,
        CASE
            WHEN (claimed_by IS NULL) THEN NULL::text
            WHEN (EXISTS ( SELECT 1
               FROM ledger.agent a
              WHERE ((a.name = t.claimed_by) AND (a.offboarded IS NULL)))) THEN 'active'::text
            WHEN (EXISTS ( SELECT 1
               FROM ledger.agent a
              WHERE (a.name = t.claimed_by))) THEN 'departed'::text
            ELSE 'not-an-agent'::text
        END AS owner_state
   FROM ledger.ticket t
  WHERE ((status <> ALL (ARRAY['archived'::ledger.ticket_status, 'passing'::ledger.ticket_status])) AND (retired_at IS NULL) AND (id !~~ 'zz\_%'::text));


--
-- Name: VIEW v_claims; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON VIEW ledger.v_claims IS 'Live claims: who holds what, and whether that owner is still here. ⚠ READABLE BY ledger_agent SINCE MIGRATION 171 -- `ledger-db.sh board` runs as the agent and was refused 42501 for the whole life of the view before that. ⚠ If this view is ever recreated with DROP VIEW rather than CREATE OR REPLACE, the grant goes with it and board breaks silently again; that has already happened once (see check-ledger-issue-list.sh''s header).';


--
-- Name: v_claim_without_a_live_owner; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_claim_without_a_live_owner AS
 SELECT id,
    title,
    area,
    status,
    claimed_by,
    claimed_at,
    owner_state
   FROM ledger.v_claims
  WHERE (owner_state = ANY (ARRAY['departed'::text, 'not-an-agent'::text]));


--
-- Name: v_comment; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_comment AS
 SELECT seq,
    ticket_id,
    body,
    author,
    author_kind,
    at,
    reviewed_at,
    reviewed_by,
    ((author_kind = 'owner'::text) AND (reviewed_at IS NULL)) AS unreviewed
   FROM ledger.comment c
  ORDER BY ticket_id, at, seq;


--
-- Name: v_drift_current; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_drift_current AS
 WITH latest AS (
         SELECT DISTINCT ON (d.id, d.field) d.id,
            d.field,
            d.found,
            d.note,
            d.at
           FROM ledger.import_drift d
          WHERE (d.id !~~ 'zz\_%'::text)
          ORDER BY d.id, d.field, d.seq DESC
        )
 SELECT l.id,
    l.field,
    l.found,
    l.note,
    l.at
   FROM (latest l
     JOIN ledger.ticket t ON ((t.id = l.id)))
  WHERE (((l.field <> ALL (ARRAY['mirror_refused'::text, 'status'::text])) AND (l.at = t.updated_at)) OR ((l.field = 'mirror_refused'::text) AND (t.mirror_refused_at IS NOT NULL)) OR ((l.field = 'status'::text) AND ((t.status)::text = 'archived'::text)));


--
-- Name: VIEW v_drift_current; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON VIEW ledger.v_drift_current IS 'Recorded drift that is STILL TRUE: the latest import_drift row per (id, field), kept only when it was written by the most recent mirror of that ticket. import_drift is an event log; this is the current-state reader it never had. Read-only.';


--
-- Name: v_frontier; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_frontier AS
 SELECT id,
    title,
    area,
    priority,
    depends_on,
    solo
   FROM ledger.ticket t
  WHERE ((status = 'selected'::ledger.ticket_status) AND (claimed_by IS NULL) AND (mirror_refused_at IS NULL) AND (retired_at IS NULL) AND (NOT (EXISTS ( SELECT 1
           FROM (unnest(t.depends_on) d(d)
             JOIN ledger.ticket dt ON ((dt.id = d.d)))
          WHERE (dt.status <> ALL (ARRAY['archived'::ledger.ticket_status, 'passing'::ledger.ticket_status]))))));


--
-- Name: v_history; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_history AS
 SELECT seq,
    ticket_id,
    verb,
    actor,
    detail,
    at
   FROM ledger.ticket_event
  WHERE (NOT ledger.is_probe(ticket_id));


--
-- Name: v_import_drift; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_import_drift AS
 SELECT entity,
    field,
    count(*) AS rows
   FROM ledger.import_drift
  WHERE (NOT ledger.is_probe(id))
  GROUP BY entity, field;


--
-- Name: v_import_drift_rows; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_import_drift_rows AS
 SELECT d.seq,
    d.entity,
    d.id,
    d.field,
    d.found,
    d.note,
    d.at,
    (t.mirror_refused_at IS NOT NULL) AS refused_now,
    t.mirror_refused_reason,
    (t.status)::text AS ticket_status
   FROM (ledger.import_drift d
     LEFT JOIN ledger.ticket t ON ((t.id = d.id)))
  WHERE (d.id !~~ 'zz\_%'::text);


--
-- Name: VIEW v_import_drift_rows; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON VIEW ledger.v_import_drift_rows IS 'Every drift row with its id, field, found, note and at — the per-row detail that v_import_drift aggregates away. ADDITIVE: v_import_drift is unchanged and keeps its own readers. `refused_now` is the ticket''s CURRENT clearable mark, so a row with field=''mirror_refused'' and refused_now=false is a refusal that has since self-resolved and is recorded NOWHERE else — see migration 14 (the mark is cleared on the next good mirror) and 58-...:443 (the durable row). No recency bound is applied here; bound on `at` at the caller.';


--
-- Name: v_legacy_import; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_legacy_import AS
 SELECT id,
    title,
    area,
    status,
    legacy_source,
    created_at
   FROM ledger.ticket
  WHERE (legacy_source IS NOT NULL);


--
-- Name: v_mirror_refused; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_mirror_refused AS
 SELECT id,
    status,
    claimed_by,
    parked_by,
    mirror_refused_at,
    mirror_refused_reason
   FROM ledger.ticket
  WHERE (mirror_refused_at IS NOT NULL)
  ORDER BY mirror_refused_at DESC;


--
-- Name: v_owner_blocked; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_owner_blocked AS
 SELECT id,
    title,
    claimed_by,
    parked_reason,
    parked_at,
    (now() - parked_at) AS waiting,
    park_summary
   FROM ledger.ticket
  WHERE ((parked_at IS NOT NULL) AND (status = 'parked'::ledger.ticket_status) AND (park_kind = 'blocked_on_owner'::ledger.park_kind));


--
-- Name: VIEW v_owner_blocked; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON VIEW ledger.v_owner_blocked IS 'The owner''s waiting-on-you list. park_summary is the one-line ask written for him; parked_reason is the long form written for tools. Read the summary and fall back to the reason — both are exposed so a reader can tell an absent ask from a written one.';


--
-- Name: v_owner_override_pending; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_owner_override_pending AS
 SELECT ticket_id,
    field,
    value,
    set_by,
    set_at,
    (now() - set_at) AS waiting_for_git
   FROM ledger.owner_override o
  ORDER BY set_at;


--
-- Name: v_park_without_owner; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_park_without_owner AS
 SELECT id,
    title,
    status,
    parked_by,
    parked_reason,
    parked_at,
    (now() - parked_at) AS parked_for,
        CASE
            WHEN (status = ANY (ARRAY['selected'::ledger.ticket_status, 'not_started'::ledger.ticket_status])) THEN 'on the ready frontier while parked -- another agent will pick up owned work'::text
            ELSE 'parked but not in progress -- no owner is carrying the remainder'::text
        END AS why_it_is_wrong
   FROM ledger.ticket
  WHERE ((parked_at IS NOT NULL) AND (status <> ALL (ARRAY['in_progress'::ledger.ticket_status, 'parked'::ledger.ticket_status, 'passing'::ledger.ticket_status, 'archived'::ledger.ticket_status, 'wont_do'::ledger.ticket_status])));


--
-- Name: v_po_queue; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_po_queue AS
 SELECT id,
    title,
    area,
    status,
    priority,
    updated_at
   FROM ledger.ticket
  WHERE ((status = ANY (ARRAY['selected'::ledger.ticket_status, 'in_progress'::ledger.ticket_status])) AND (claimed_by IS NULL))
  ORDER BY (status = 'in_progress'::ledger.ticket_status) DESC, priority, id;


--
-- Name: v_request; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_request AS
 SELECT r.seq,
    r.raw,
    r.note,
    r.raised_by,
    r.raised_at,
    r.ticket_id,
    t.status AS ticket_status,
    t.title AS ticket_title,
    r.dismissed_reason,
    r.dismissed_at,
    r.dismissed_by,
        CASE
            WHEN (r.ticket_id IS NOT NULL) THEN 'ticketed'::text
            WHEN (r.dismissed_at IS NOT NULL) THEN 'dismissed'::text
            ELSE 'outstanding'::text
        END AS state
   FROM (ledger.request r
     LEFT JOIN ledger.ticket t ON ((t.id = r.ticket_id)))
  ORDER BY r.raised_at DESC, r.seq DESC;


--
-- Name: v_request_summary; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_request_summary AS
 SELECT count(*) AS raised,
    count(*) FILTER (WHERE (ticket_id IS NOT NULL)) AS ticketed,
    count(*) FILTER (WHERE (dismissed_at IS NOT NULL)) AS dismissed,
    count(*) FILTER (WHERE ((ticket_id IS NULL) AND (dismissed_at IS NULL))) AS outstanding,
    min(raised_at) FILTER (WHERE ((ticket_id IS NULL) AND (dismissed_at IS NULL))) AS oldest_outstanding
   FROM ledger.request;


--
-- Name: v_retired; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_retired AS
 SELECT id,
    title,
    area,
    (status)::text AS status_when_retired,
    retired_at,
    retired_by,
    retired_reason,
    ledger.is_probe(id) AS is_probe,
    (now() - retired_at) AS retired_for
   FROM ledger.ticket t
  WHERE (retired_at IS NOT NULL)
  ORDER BY retired_at DESC;


--
-- Name: v_session_entry; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_session_entry AS
 SELECT id,
    agent,
    written_at,
    ticket_id,
    branch,
    pr,
    title,
    body
   FROM ledger.session_entry e
  ORDER BY written_at DESC, id DESC;


--
-- Name: v_specialism; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_specialism AS
 SELECT name,
    axis,
    area,
    description,
    (retired_at IS NOT NULL) AS retired,
    ( SELECT count(*) AS count
           FROM ledger.agent_specialism a
          WHERE (a.specialism = s.name)) AS held_by,
    ( SELECT count(*) AS count
           FROM ledger.ticket t
          WHERE ((s.axis = 'area'::text) AND (t.area = s.area) AND (t.status <> 'archived'::ledger.ticket_status) AND (NOT ledger.is_probe(t.id)))) AS live_tickets
   FROM ledger.specialism s;


--
-- Name: v_ticket; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_ticket AS
 SELECT id,
    title,
    area,
    status,
    priority,
    claimed_by,
    claimed_at,
    parked_reason,
    parked_at,
    parked_by,
    verified_by_pr,
    issue,
    solo,
    depends_on,
    parent,
    updated_at,
    delivered_by
   FROM ledger.ticket;


--
-- Name: v_ticket_activity; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_ticket_activity AS
 WITH ev AS (
         SELECT ticket_event.ticket_id,
            ticket_event.verb AS kind,
            ticket_event.at
           FROM ledger.ticket_event
          WHERE (ticket_event.verb <> 'mirrored'::text)
        ), prs AS (
         SELECT pr.ticket_id,
            ('pr_'::text || pr.state) AS kind,
            GREATEST(COALESCE(pr.merged_at, '1970-01-01 00:00:00+00'::timestamp with time zone), COALESCE(pr.closed_at, '1970-01-01 00:00:00+00'::timestamp with time zone), COALESCE(pr.check_updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), COALESCE(pr.opened_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS at
           FROM ledger.pr
        ), activity AS (
         SELECT ev.ticket_id,
            ev.kind,
            ev.at
           FROM ev
        UNION ALL
         SELECT prs.ticket_id,
            prs.kind,
            prs.at
           FROM prs
        )
 SELECT DISTINCT ON (ticket_id) ticket_id,
    kind AS last_activity_kind,
    at AS last_activity_at,
    (now() - at) AS last_activity_age
   FROM activity
  WHERE ((at > '1970-01-01 00:00:00+00'::timestamp with time zone) AND (NOT ledger.is_probe(ticket_id)))
  ORDER BY ticket_id, at DESC;


--
-- Name: VIEW v_ticket_activity; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON VIEW ledger.v_ticket_activity IS 'Last REAL activity per ticket (docs/ledger-spec.md §4). Excludes the mirror verb, which records that a file was copied rather than that anything happened. A ticket absent from this view has no activity yet — which is NOT the same as GitHub being unreadable; see ledger.github_poll.';


--
-- Name: v_ticket_detail; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_ticket_detail AS
 SELECT id,
    title,
    (status)::text AS status,
    area,
    priority,
    user_visible_behavior,
    notes,
    verification,
    verification_command,
    claimed_by,
    parked_reason,
    issue,
    verified_by_pr,
    created_at,
    updated_at,
    ( SELECT count(*) AS count
           FROM ledger.comment c
          WHERE (c.ticket_id = t.id)) AS comments,
    ( SELECT count(*) AS count
           FROM ledger.comment c
          WHERE ((c.ticket_id = t.id) AND (c.author_kind = 'owner'::text) AND (c.reviewed_at IS NULL))) AS unreviewed,
    parked_by,
    parked_at,
    (park_kind)::text AS park_kind,
        CASE
            WHEN (jsonb_typeof((extra -> 'blocked_on'::text)) = 'array'::text) THEN ARRAY( SELECT jsonb_array_elements_text((t.extra -> 'blocked_on'::text)) AS jsonb_array_elements_text)
            WHEN (NULLIF((extra ->> 'blocked_on'::text), ''::text) IS NOT NULL) THEN ARRAY[(extra ->> 'blocked_on'::text)]
            ELSE NULL::text[]
        END AS blocked_on,
    NULLIF((extra ->> 'blocked_reason'::text), ''::text) AS blocked_reason,
    ( SELECT COALESCE(array_agg(DISTINCT m.ref[1]), ARRAY[]::text[]) AS "coalesce"
           FROM (regexp_matches(concat_ws(' '::text, t.parked_reason, t.park_summary, (t.extra ->> 'blocked_reason'::text),
                CASE
                    WHEN (jsonb_typeof((t.extra -> 'blocked_on'::text)) = 'array'::text) THEN ( SELECT string_agg(x.value, ' '::text) AS string_agg
                       FROM jsonb_array_elements_text((t.extra -> 'blocked_on'::text)) x(value))
                    ELSE (t.extra ->> 'blocked_on'::text)
                END), '([a-z][a-z0-9]*(?:_[a-z0-9]+){2,})'::text, 'g'::text) m(ref)
             JOIN ledger.ticket r ON ((r.id = m.ref[1])))
          WHERE (r.id <> t.id)) AS referenced_ids,
    park_summary,
    ref
   FROM ledger.ticket t;


--
-- Name: VIEW v_ticket_detail; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON VIEW ledger.v_ticket_detail IS 'One ticket in full, for the admin ticket page. Carries all four park columns, the blocked axis out of extra (blocked_on as text[], blocked_reason), and referenced_ids — the ids this ticket NAMES that actually exist. A reader must linkify only ids in referenced_ids: a third of the id-shaped strings in these fields resolve to nothing, and a link that 404s is worse than text. See migrations 53 and 61.';


--
-- Name: v_ticket_history; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_ticket_history AS
 SELECT seq,
    ticket_id,
    verb,
    actor,
    at,
    (detail ->> 'from'::text) AS from_status,
    (detail ->> 'to'::text) AS to_status,
    COALESCE((detail ->> 'reason'::text), (detail ->> 'why'::text)) AS reason,
    detail
   FROM ledger.ticket_event e
  WHERE ((verb <> 'mirrored'::text) AND (NOT ledger.is_probe(ticket_id)));


--
-- Name: VIEW v_ticket_history; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON VIEW ledger.v_ticket_history IS 'Meaningful ticket history for a person: every recorded verb, mirror snapshots excluded. v_history is the raw passthrough and is 99.9% mirrored rows; read this one instead.';


--
-- Name: v_ticket_list; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_ticket_list AS
 SELECT id,
    title,
    claimed_by,
    (status)::text AS status,
    area,
    updated_at,
    ( SELECT count(*) AS count
           FROM ledger.comment c
          WHERE ((c.ticket_id = t.id) AND (c.author_kind = 'owner'::text) AND (c.reviewed_at IS NULL))) AS unreviewed,
        CASE
            WHEN (( SELECT max(c.at) AS max
               FROM ledger.comment c
              WHERE ((c.ticket_id = t.id) AND (c.author_kind = 'owner'::text))) IS NULL) THEN NULL::text
            WHEN (( SELECT max(c.at) AS max
               FROM ledger.comment c
              WHERE ((c.ticket_id = t.id) AND (c.author_kind <> 'owner'::text))) > ( SELECT max(c.at) AS max
               FROM ledger.comment c
              WHERE ((c.ticket_id = t.id) AND (c.author_kind = 'owner'::text)))) THEN 'answered'::text
            ELSE 'awaiting_you'::text
        END AS answer_state,
    ( SELECT min(e.at) AS min
           FROM ledger.ticket_event e
          WHERE ((e.ticket_id = t.id) AND (e.verb = 'raised'::text))) AS raised_at,
    ref
   FROM ledger.ticket t
  WHERE ((retired_at IS NULL) AND (id !~~ 'zz\_%'::text));


--
-- Name: VIEW v_ticket_list; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON VIEW ledger.v_ticket_list IS 'The board''s list projection. Since migration 169 it also carries raised_at -- the time of the ticket''s real `raised` event, NULL when none was recorded. ⚠ raised_at is NOT ledger.ticket.created_at and must never be coalesced to it: created_at is the ROW IMPORT time for the ~3,740 rows backfilled on 2026-08-26 and 2026-09-15, and is the true raise time only for tickets raised since the event log began on 2026-09-15 (driven: 108 of 108 agree within 60s, 0 disagree). A consumer that substitutes created_at asserts a raise that did not happen for 83% of the board, and under column sorting the backfill ordering becomes the board''s narrative.';


--
-- Name: v_ticket_pr; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_ticket_pr AS
 SELECT ticket_id,
    pr_number,
    title,
    state,
    merged_at,
    directive,
    collected_at
   FROM ledger.ticket_pr p
  ORDER BY ticket_id, (merged_at IS NULL), pr_number;


--
-- Name: v_ticket_requirement; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_ticket_requirement AS
 SELECT id,
    (status)::text AS status,
    area,
    evidence,
    acceptance,
    last_verified_commit,
    raised_by,
    extra
   FROM ledger.ticket t;


--
-- Name: VIEW v_ticket_requirement; Type: COMMENT; Schema: ledger; Owner: -
--

COMMENT ON VIEW ledger.v_ticket_requirement IS 'Requirement/verification fields and the unmodelled tail (extra), for readers below ledger_owner. ledger.ticket is granted to no agent-tier role, so this is the only path to these seven fields.';


--
-- Name: v_ticket_status_counts; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_ticket_status_counts AS
 SELECT (s.status)::text AS status,
    count(t.id) AS n
   FROM (unnest(enum_range(NULL::ledger.ticket_status)) s(status)
     LEFT JOIN ledger.ticket t ON (((t.status = s.status) AND (NOT ledger.is_probe(t.id)) AND (t.retired_at IS NULL))))
  GROUP BY s.status
  ORDER BY s.status;


--
-- Name: v_unreviewed_summary; Type: VIEW; Schema: ledger; Owner: -
--

CREATE VIEW ledger.v_unreviewed_summary AS
 SELECT count(*) AS unreviewed,
    count(DISTINCT ticket_id) AS tickets,
    min(at) AS oldest,
    (EXTRACT(epoch FROM (now() - min(at))))::bigint AS oldest_age_s
   FROM ledger.comment
  WHERE ((author_kind = 'owner'::text) AND (reviewed_at IS NULL));


--
-- Name: admin_event seq; Type: DEFAULT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.admin_event ALTER COLUMN seq SET DEFAULT nextval('ledger.admin_event_seq_seq'::regclass);


--
-- Name: comment seq; Type: DEFAULT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.comment ALTER COLUMN seq SET DEFAULT nextval('ledger.comment_seq_seq'::regclass);


--
-- Name: import_drift seq; Type: DEFAULT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.import_drift ALTER COLUMN seq SET DEFAULT nextval('ledger.import_drift_seq_seq'::regclass);


--
-- Name: request seq; Type: DEFAULT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.request ALTER COLUMN seq SET DEFAULT nextval('ledger.request_seq_seq'::regclass);


--
-- Name: session_entry id; Type: DEFAULT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.session_entry ALTER COLUMN id SET DEFAULT nextval('ledger.session_entry_id_seq'::regclass);


--
-- Name: sync_run seq; Type: DEFAULT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.sync_run ALTER COLUMN seq SET DEFAULT nextval('ledger.sync_run_seq_seq'::regclass);


--
-- Name: ticket ref; Type: DEFAULT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.ticket ALTER COLUMN ref SET DEFAULT nextval('ledger.ticket_ref_seq'::regclass);


--
-- Name: ticket_event seq; Type: DEFAULT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.ticket_event ALTER COLUMN seq SET DEFAULT nextval('ledger.ticket_event_seq_seq'::regclass);


--
-- Name: admin_event admin_event_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.admin_event
    ADD CONSTRAINT admin_event_pkey PRIMARY KEY (seq);


--
-- Name: agent agent_email_key; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.agent
    ADD CONSTRAINT agent_email_key UNIQUE (email);


--
-- Name: agent agent_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.agent
    ADD CONSTRAINT agent_pkey PRIMARY KEY (name);


--
-- Name: agent_role agent_role_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.agent_role
    ADD CONSTRAINT agent_role_pkey PRIMARY KEY (name);


--
-- Name: agent_specialism agent_specialism_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.agent_specialism
    ADD CONSTRAINT agent_specialism_pkey PRIMARY KEY (agent, specialism);


--
-- Name: area area_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.area
    ADD CONSTRAINT area_pkey PRIMARY KEY (name);


--
-- Name: area_synonym area_synonym_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.area_synonym
    ADD CONSTRAINT area_synonym_pkey PRIMARY KEY (alias);


--
-- Name: comment comment_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.comment
    ADD CONSTRAINT comment_pkey PRIMARY KEY (seq);


--
-- Name: github_poll github_poll_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.github_poll
    ADD CONSTRAINT github_poll_pkey PRIMARY KEY (id);


--
-- Name: import_drift import_drift_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.import_drift
    ADD CONSTRAINT import_drift_pkey PRIMARY KEY (seq);


--
-- Name: owner_override owner_override_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.owner_override
    ADD CONSTRAINT owner_override_pkey PRIMARY KEY (ticket_id, field);


--
-- Name: pr pr_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.pr
    ADD CONSTRAINT pr_pkey PRIMARY KEY (number);


--
-- Name: request request_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.request
    ADD CONSTRAINT request_pkey PRIMARY KEY (seq);


--
-- Name: schema_migration schema_migration_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.schema_migration
    ADD CONSTRAINT schema_migration_pkey PRIMARY KEY (filename);


--
-- Name: session_entry session_entry_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.session_entry
    ADD CONSTRAINT session_entry_pkey PRIMARY KEY (id);


--
-- Name: specialism specialism_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.specialism
    ADD CONSTRAINT specialism_pkey PRIMARY KEY (name);


--
-- Name: sync_run sync_run_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.sync_run
    ADD CONSTRAINT sync_run_pkey PRIMARY KEY (seq);


--
-- Name: ticket_event ticket_event_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.ticket_event
    ADD CONSTRAINT ticket_event_pkey PRIMARY KEY (seq);


--
-- Name: ticket ticket_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.ticket
    ADD CONSTRAINT ticket_pkey PRIMARY KEY (id);


--
-- Name: ticket_pr ticket_pr_pkey; Type: CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.ticket_pr
    ADD CONSTRAINT ticket_pr_pkey PRIMARY KEY (ticket_id, pr_number);


--
-- Name: comment_by_ticket; Type: INDEX; Schema: ledger; Owner: -
--

CREATE INDEX comment_by_ticket ON ledger.comment USING btree (ticket_id, at);


--
-- Name: comment_unreviewed; Type: INDEX; Schema: ledger; Owner: -
--

CREATE INDEX comment_unreviewed ON ledger.comment USING btree (at) WHERE ((author_kind = 'owner'::text) AND (reviewed_at IS NULL));


--
-- Name: ix_session_entry_agent_written; Type: INDEX; Schema: ledger; Owner: -
--

CREATE INDEX ix_session_entry_agent_written ON ledger.session_entry USING btree (agent, written_at DESC);


--
-- Name: ix_session_entry_ticket; Type: INDEX; Schema: ledger; Owner: -
--

CREATE INDEX ix_session_entry_ticket ON ledger.session_entry USING btree (ticket_id) WHERE (ticket_id IS NOT NULL);


--
-- Name: ix_ticket_pr_ticket; Type: INDEX; Schema: ledger; Owner: -
--

CREATE INDEX ix_ticket_pr_ticket ON ledger.ticket_pr USING btree (ticket_id);


--
-- Name: one_primary_per_agent; Type: INDEX; Schema: ledger; Owner: -
--

CREATE UNIQUE INDEX one_primary_per_agent ON ledger.agent_specialism USING btree (agent) WHERE (depth = 'primary'::ledger.depth);


--
-- Name: pr_ticket_idx; Type: INDEX; Schema: ledger; Owner: -
--

CREATE INDEX pr_ticket_idx ON ledger.pr USING btree (ticket_id);


--
-- Name: sync_run_main_at_idx; Type: INDEX; Schema: ledger; Owner: -
--

CREATE INDEX sync_run_main_at_idx ON ledger.sync_run USING btree (at DESC) WHERE (mode = 'main'::text);


--
-- Name: ticket_event_raised_idx; Type: INDEX; Schema: ledger; Owner: -
--

CREATE INDEX ticket_event_raised_idx ON ledger.ticket_event USING btree (ticket_id, at) WHERE (verb = 'raised'::text);


--
-- Name: ticket_legacy_source; Type: INDEX; Schema: ledger; Owner: -
--

CREATE INDEX ticket_legacy_source ON ledger.ticket USING btree (legacy_source) WHERE (legacy_source IS NOT NULL);


--
-- Name: ticket_ref_key; Type: INDEX; Schema: ledger; Owner: -
--

CREATE UNIQUE INDEX ticket_ref_key ON ledger.ticket USING btree (ref);


--
-- Name: ticket an_ask_belongs_to_a_park; Type: TRIGGER; Schema: ledger; Owner: -
--

CREATE TRIGGER an_ask_belongs_to_a_park BEFORE INSERT OR UPDATE ON ledger.ticket FOR EACH ROW EXECUTE FUNCTION ledger.an_ask_belongs_to_a_park();


--
-- Name: admin_event no_mutation; Type: TRIGGER; Schema: ledger; Owner: -
--

CREATE TRIGGER no_mutation BEFORE DELETE OR UPDATE ON ledger.admin_event FOR EACH ROW EXECUTE FUNCTION ledger.refuse_mutation();


--
-- Name: import_drift no_mutation; Type: TRIGGER; Schema: ledger; Owner: -
--

CREATE TRIGGER no_mutation BEFORE DELETE OR UPDATE ON ledger.import_drift FOR EACH ROW EXECUTE FUNCTION ledger.refuse_mutation();


--
-- Name: schema_migration no_mutation; Type: TRIGGER; Schema: ledger; Owner: -
--

CREATE TRIGGER no_mutation BEFORE DELETE OR UPDATE ON ledger.schema_migration FOR EACH ROW EXECUTE FUNCTION ledger.refuse_mutation();


--
-- Name: ticket_event no_mutation; Type: TRIGGER; Schema: ledger; Owner: -
--

CREATE TRIGGER no_mutation BEFORE DELETE OR UPDATE ON ledger.ticket_event FOR EACH ROW EXECUTE FUNCTION ledger.refuse_mutation();


--
-- Name: comment no_rewrite; Type: TRIGGER; Schema: ledger; Owner: -
--

CREATE TRIGGER no_rewrite BEFORE DELETE OR UPDATE ON ledger.comment FOR EACH ROW EXECUTE FUNCTION ledger.refuse_comment_rewrite();


--
-- Name: admin_event no_truncate; Type: TRIGGER; Schema: ledger; Owner: -
--

CREATE TRIGGER no_truncate BEFORE TRUNCATE ON ledger.admin_event FOR EACH STATEMENT EXECUTE FUNCTION ledger.refuse_mutation();


--
-- Name: import_drift no_truncate; Type: TRIGGER; Schema: ledger; Owner: -
--

CREATE TRIGGER no_truncate BEFORE TRUNCATE ON ledger.import_drift FOR EACH STATEMENT EXECUTE FUNCTION ledger.refuse_mutation();


--
-- Name: schema_migration no_truncate; Type: TRIGGER; Schema: ledger; Owner: -
--

CREATE TRIGGER no_truncate BEFORE TRUNCATE ON ledger.schema_migration FOR EACH STATEMENT EXECUTE FUNCTION ledger.refuse_mutation();


--
-- Name: ticket_event no_truncate; Type: TRIGGER; Schema: ledger; Owner: -
--

CREATE TRIGGER no_truncate BEFORE TRUNCATE ON ledger.ticket_event FOR EACH STATEMENT EXECUTE FUNCTION ledger.refuse_mutation();


--
-- Name: ticket trg_enforce_owner_override; Type: TRIGGER; Schema: ledger; Owner: -
--

CREATE TRIGGER trg_enforce_owner_override BEFORE UPDATE ON ledger.ticket FOR EACH ROW EXECUTE FUNCTION ledger.enforce_owner_override();


--
-- Name: ticket trg_log_extra_key_withdrawal; Type: TRIGGER; Schema: ledger; Owner: -
--

CREATE TRIGGER trg_log_extra_key_withdrawal AFTER UPDATE ON ledger.ticket FOR EACH ROW WHEN ((old.extra IS DISTINCT FROM new.extra)) EXECUTE FUNCTION ledger.log_extra_key_withdrawal();


--
-- Name: ticket trg_normalise_shaped_extra_keys; Type: TRIGGER; Schema: ledger; Owner: -
--

CREATE TRIGGER trg_normalise_shaped_extra_keys BEFORE INSERT OR UPDATE ON ledger.ticket FOR EACH ROW EXECUTE FUNCTION ledger.normalise_shaped_extra_keys_trg();


--
-- Name: ticket trg_passing_finish_needs_a_pointer; Type: TRIGGER; Schema: ledger; Owner: -
--

CREATE TRIGGER trg_passing_finish_needs_a_pointer BEFORE INSERT OR UPDATE ON ledger.ticket FOR EACH ROW EXECUTE FUNCTION ledger.refuse_a_passing_finish_without_a_verification_pointer();


--
-- Name: ticket trg_updated_at_only_on_a_real_change; Type: TRIGGER; Schema: ledger; Owner: -
--

CREATE TRIGGER trg_updated_at_only_on_a_real_change BEFORE UPDATE ON ledger.ticket FOR EACH ROW EXECUTE FUNCTION ledger.updated_at_only_on_a_real_change();


--
-- Name: ticket trg_waiting_on_owner_requires_an_ask; Type: TRIGGER; Schema: ledger; Owner: -
--

CREATE TRIGGER trg_waiting_on_owner_requires_an_ask BEFORE INSERT OR UPDATE ON ledger.ticket FOR EACH ROW EXECUTE FUNCTION ledger.waiting_on_owner_requires_an_ask();


--
-- Name: agent agent_role_fkey; Type: FK CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.agent
    ADD CONSTRAINT agent_role_fkey FOREIGN KEY (role) REFERENCES ledger.agent_role(name);


--
-- Name: agent_specialism agent_specialism_agent_fkey; Type: FK CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.agent_specialism
    ADD CONSTRAINT agent_specialism_agent_fkey FOREIGN KEY (agent) REFERENCES ledger.agent(name) ON DELETE CASCADE;


--
-- Name: agent_specialism agent_specialism_specialism_fkey; Type: FK CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.agent_specialism
    ADD CONSTRAINT agent_specialism_specialism_fkey FOREIGN KEY (specialism) REFERENCES ledger.specialism(name);


--
-- Name: area_synonym area_synonym_area_fkey; Type: FK CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.area_synonym
    ADD CONSTRAINT area_synonym_area_fkey FOREIGN KEY (area) REFERENCES ledger.area(name);


--
-- Name: comment comment_ticket_id_fkey; Type: FK CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.comment
    ADD CONSTRAINT comment_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES ledger.ticket(id);


--
-- Name: owner_override owner_override_ticket_id_fkey; Type: FK CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.owner_override
    ADD CONSTRAINT owner_override_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES ledger.ticket(id) ON DELETE CASCADE;


--
-- Name: pr pr_ticket_id_fkey; Type: FK CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.pr
    ADD CONSTRAINT pr_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES ledger.ticket(id);


--
-- Name: request request_ticket_id_fkey; Type: FK CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.request
    ADD CONSTRAINT request_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES ledger.ticket(id);


--
-- Name: session_entry session_entry_agent_fkey; Type: FK CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.session_entry
    ADD CONSTRAINT session_entry_agent_fkey FOREIGN KEY (agent) REFERENCES ledger.agent(name);


--
-- Name: session_entry session_entry_ticket_id_fkey; Type: FK CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.session_entry
    ADD CONSTRAINT session_entry_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES ledger.ticket(id) ON DELETE SET NULL;


--
-- Name: specialism specialism_area_fkey; Type: FK CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.specialism
    ADD CONSTRAINT specialism_area_fkey FOREIGN KEY (area) REFERENCES ledger.area(name);


--
-- Name: ticket ticket_adjudicated_by_fkey; Type: FK CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.ticket
    ADD CONSTRAINT ticket_adjudicated_by_fkey FOREIGN KEY (adjudicated_by) REFERENCES ledger.agent(name);


--
-- Name: ticket ticket_area_fkey; Type: FK CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.ticket
    ADD CONSTRAINT ticket_area_fkey FOREIGN KEY (area) REFERENCES ledger.area(name);


--
-- Name: ticket ticket_claimed_by_fkey; Type: FK CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.ticket
    ADD CONSTRAINT ticket_claimed_by_fkey FOREIGN KEY (claimed_by) REFERENCES ledger.agent(name);


--
-- Name: ticket_event ticket_event_ticket_id_fkey; Type: FK CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.ticket_event
    ADD CONSTRAINT ticket_event_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES ledger.ticket(id);


--
-- Name: ticket ticket_parked_by_fkey; Type: FK CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.ticket
    ADD CONSTRAINT ticket_parked_by_fkey FOREIGN KEY (parked_by) REFERENCES ledger.agent(name);


--
-- Name: ticket_pr ticket_pr_ticket_id_fkey; Type: FK CONSTRAINT; Schema: ledger; Owner: -
--

ALTER TABLE ONLY ledger.ticket_pr
    ADD CONSTRAINT ticket_pr_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES ledger.ticket(id) ON DELETE CASCADE;


--
-- Name: SCHEMA ledger; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA ledger TO ledger_agent;
GRANT USAGE ON SCHEMA ledger TO ledger_console;


--
-- Name: FUNCTION add_comment(p_ticket text, p_body text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.add_comment(p_ticket text, p_body text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.add_comment(p_ticket text, p_body text) TO ledger_console;
GRANT ALL ON FUNCTION ledger.add_comment(p_ticket text, p_body text) TO ledger_agent;


--
-- Name: FUNCTION adjudicate_retired_park(p_id text, p_outcome text, p_reason text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.adjudicate_retired_park(p_id text, p_outcome text, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.adjudicate_retired_park(p_id text, p_outcome text, p_reason text) TO ledger_agent;


--
-- Name: FUNCTION answer_from_owner(p_id text, p_reply text, p_waiting_on text, p_actor text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.answer_from_owner(p_id text, p_reply text, p_waiting_on text, p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.answer_from_owner(p_id text, p_reply text, p_waiting_on text, p_actor text) TO ledger_console;


--
-- Name: FUNCTION append_delivery_note(p_id text, p_note text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.append_delivery_note(p_id text, p_note text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.append_delivery_note(p_id text, p_note text) TO ledger_agent;
GRANT ALL ON FUNCTION ledger.append_delivery_note(p_id text, p_note text) TO ledger_console;


--
-- Name: FUNCTION assign_specialism(p_agent text, p_specialism text, p_depth text, p_note text, p_actor text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.assign_specialism(p_agent text, p_specialism text, p_depth text, p_note text, p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.assign_specialism(p_agent text, p_specialism text, p_depth text, p_note text, p_actor text) TO ledger_console;
GRANT ALL ON FUNCTION ledger.assign_specialism(p_agent text, p_specialism text, p_depth text, p_note text, p_actor text) TO ledger_agent;


--
-- Name: FUNCTION claim(p_id text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.claim(p_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.claim(p_id text) TO ledger_agent;


--
-- Name: FUNCTION create_draft_ticket(p_id text, p_title text, p_area text, p_body text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.create_draft_ticket(p_id text, p_title text, p_area text, p_body text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.create_draft_ticket(p_id text, p_title text, p_area text, p_body text) TO ledger_console;


--
-- Name: FUNCTION drift_original(p_id text, p_field text); Type: ACL; Schema: ledger; Owner: -
--

GRANT ALL ON FUNCTION ledger.drift_original(p_id text, p_field text) TO ledger_console;
GRANT ALL ON FUNCTION ledger.drift_original(p_id text, p_field text) TO ledger_agent;


--
-- Name: FUNCTION flip_passing(p_id text, p_pr integer); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.flip_passing(p_id text, p_pr integer) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.flip_passing(p_id text, p_pr integer) TO ledger_agent;


--
-- Name: FUNCTION import_legacy_ticket(p jsonb, p_source text); Type: ACL; Schema: ledger; Owner: -
--

GRANT ALL ON FUNCTION ledger.import_legacy_ticket(p jsonb, p_source text) TO ledger_console;
GRANT ALL ON FUNCTION ledger.import_legacy_ticket(p jsonb, p_source text) TO ledger_agent;


--
-- Name: FUNCTION mirror_ticket(p jsonb); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.mirror_ticket(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.mirror_ticket(p jsonb) TO ledger_agent;
GRANT ALL ON FUNCTION ledger.mirror_ticket(p jsonb) TO ledger_console;


--
-- Name: FUNCTION owner_set_field(p_id text, p_field text, p_value text, p_actor text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.owner_set_field(p_id text, p_field text, p_value text, p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.owner_set_field(p_id text, p_field text, p_value text, p_actor text) TO ledger_console;


--
-- Name: FUNCTION park(p_id text, p_reason text, p_kind ledger.park_kind, p_summary text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.park(p_id text, p_reason text, p_kind ledger.park_kind, p_summary text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.park(p_id text, p_reason text, p_kind ledger.park_kind, p_summary text) TO ledger_agent;


--
-- Name: FUNCTION park_is_adjudicated_to_the_product_owner(p_status ledger.ticket_status, p_claimed_by text, p_adjudicated_from text, p_actor text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.park_is_adjudicated_to_the_product_owner(p_status ledger.ticket_status, p_claimed_by text, p_adjudicated_from text, p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.park_is_adjudicated_to_the_product_owner(p_status ledger.ticket_status, p_claimed_by text, p_adjudicated_from text, p_actor text) TO ledger_agent;


--
-- Name: FUNCTION priority_of(p_raw text); Type: ACL; Schema: ledger; Owner: -
--

GRANT ALL ON FUNCTION ledger.priority_of(p_raw text) TO ledger_console;
GRANT ALL ON FUNCTION ledger.priority_of(p_raw text) TO ledger_agent;


--
-- Name: FUNCTION priority_of_strict(p_raw text); Type: ACL; Schema: ledger; Owner: -
--

GRANT ALL ON FUNCTION ledger.priority_of_strict(p_raw text) TO ledger_console;
GRANT ALL ON FUNCTION ledger.priority_of_strict(p_raw text) TO ledger_agent;


--
-- Name: FUNCTION promote_reviewed_ticket(p_id text, p_status text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.promote_reviewed_ticket(p_id text, p_status text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.promote_reviewed_ticket(p_id text, p_status text) TO ledger_console;


--
-- Name: FUNCTION reclassify_park(p_id text, p_kind ledger.park_kind, p_why text); Type: ACL; Schema: ledger; Owner: -
--

GRANT ALL ON FUNCTION ledger.reclassify_park(p_id text, p_kind ledger.park_kind, p_why text) TO ledger_agent;


--
-- Name: FUNCTION release_retired_claim(p_id text, p_reason text); Type: ACL; Schema: ledger; Owner: -
--

GRANT ALL ON FUNCTION ledger.release_retired_claim(p_id text, p_reason text) TO ledger_console;


--
-- Name: FUNCTION retire_satisfied_overrides(p jsonb); Type: ACL; Schema: ledger; Owner: -
--

GRANT ALL ON FUNCTION ledger.retire_satisfied_overrides(p jsonb) TO ledger_console;
GRANT ALL ON FUNCTION ledger.retire_satisfied_overrides(p jsonb) TO ledger_agent;


--
-- Name: FUNCTION retire_specialism(p_name text, p_actor text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.retire_specialism(p_name text, p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.retire_specialism(p_name text, p_actor text) TO ledger_console;


--
-- Name: FUNCTION retire_ticket(p_id text, p_reason text, p_actor text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.retire_ticket(p_id text, p_reason text, p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.retire_ticket(p_id text, p_reason text, p_actor text) TO ledger_console;
GRANT ALL ON FUNCTION ledger.retire_ticket(p_id text, p_reason text, p_actor text) TO ledger_agent;


--
-- Name: FUNCTION review_comment(p_seq bigint); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.review_comment(p_seq bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.review_comment(p_seq bigint) TO ledger_console;
GRANT ALL ON FUNCTION ledger.review_comment(p_seq bigint) TO ledger_agent;


--
-- Name: FUNCTION review_ticket(p_id text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.review_ticket(p_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.review_ticket(p_id text) TO ledger_console;
GRANT ALL ON FUNCTION ledger.review_ticket(p_id text) TO ledger_agent;


--
-- Name: FUNCTION set_lock_intent(p_id text, p_intent text, p_note text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.set_lock_intent(p_id text, p_intent text, p_note text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.set_lock_intent(p_id text, p_intent text, p_note text) TO ledger_agent;


--
-- Name: FUNCTION set_remit(p_agent text, p_remit text, p_actor text); Type: ACL; Schema: ledger; Owner: -
--

GRANT ALL ON FUNCTION ledger.set_remit(p_agent text, p_remit text, p_actor text) TO ledger_agent;
GRANT ALL ON FUNCTION ledger.set_remit(p_agent text, p_remit text, p_actor text) TO ledger_console;


--
-- Name: FUNCTION set_role(p_agent text, p_role text, p_actor text); Type: ACL; Schema: ledger; Owner: -
--

GRANT ALL ON FUNCTION ledger.set_role(p_agent text, p_role text, p_actor text) TO ledger_agent;
GRANT ALL ON FUNCTION ledger.set_role(p_agent text, p_role text, p_actor text) TO ledger_console;


--
-- Name: FUNCTION set_ticket_description(p_id text, p_body text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.set_ticket_description(p_id text, p_body text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.set_ticket_description(p_id text, p_body text) TO ledger_console;


--
-- Name: FUNCTION sync_agent_login_roles(); Type: ACL; Schema: ledger; Owner: -
--

GRANT ALL ON FUNCTION ledger.sync_agent_login_roles() TO ledger_console;


--
-- Name: FUNCTION unassign_specialism(p_agent text, p_specialism text, p_actor text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.unassign_specialism(p_agent text, p_specialism text, p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.unassign_specialism(p_agent text, p_specialism text, p_actor text) TO ledger_console;
GRANT ALL ON FUNCTION ledger.unassign_specialism(p_agent text, p_specialism text, p_actor text) TO ledger_agent;


--
-- Name: FUNCTION unretire_ticket(p_id text, p_reason text, p_actor text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.unretire_ticket(p_id text, p_reason text, p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.unretire_ticket(p_id text, p_reason text, p_actor text) TO ledger_console;
GRANT ALL ON FUNCTION ledger.unretire_ticket(p_id text, p_reason text, p_actor text) TO ledger_agent;


--
-- Name: FUNCTION upsert_specialism(p_name text, p_axis text, p_area text, p_description text, p_actor text); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.upsert_specialism(p_name text, p_axis text, p_area text, p_description text, p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.upsert_specialism(p_name text, p_axis text, p_area text, p_description text, p_actor text) TO ledger_console;


--
-- Name: FUNCTION write_session_entry(p jsonb); Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON FUNCTION ledger.write_session_entry(p jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION ledger.write_session_entry(p jsonb) TO ledger_agent;


--
-- Name: TABLE admin_event; Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON TABLE ledger.admin_event FROM ledger_owner;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE ON TABLE ledger.admin_event TO ledger_owner;
GRANT SELECT ON TABLE ledger.admin_event TO ledger_console;


--
-- Name: TABLE agent; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.agent TO ledger_console;


--
-- Name: TABLE agent_role; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.agent_role TO ledger_console;


--
-- Name: TABLE agent_specialism; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.agent_specialism TO ledger_console;


--
-- Name: TABLE area; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.area TO ledger_console;


--
-- Name: TABLE area_synonym; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.area_synonym TO ledger_console;


--
-- Name: TABLE comment; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.comment TO ledger_console;


--
-- Name: TABLE github_poll; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.github_poll TO ledger_console;


--
-- Name: TABLE import_drift; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.import_drift TO ledger_console;


--
-- Name: TABLE owner_override; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.owner_override TO ledger_console;
GRANT SELECT ON TABLE ledger.owner_override TO ledger_agent;


--
-- Name: TABLE pr; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.pr TO ledger_console;


--
-- Name: TABLE request; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.request TO ledger_agent;
GRANT SELECT ON TABLE ledger.request TO ledger_console;


--
-- Name: SEQUENCE request_seq_seq; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE ledger.request_seq_seq TO ledger_console;


--
-- Name: TABLE schema_migration; Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON TABLE ledger.schema_migration FROM ledger_owner;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE ON TABLE ledger.schema_migration TO ledger_owner;
GRANT SELECT ON TABLE ledger.schema_migration TO ledger_console;
GRANT SELECT ON TABLE ledger.schema_migration TO ledger_agent;


--
-- Name: TABLE session_entry; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.session_entry TO ledger_console;


--
-- Name: TABLE specialism; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.specialism TO ledger_console;


--
-- Name: TABLE sync_run; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT,INSERT ON TABLE ledger.sync_run TO ledger_console;
GRANT SELECT,INSERT ON TABLE ledger.sync_run TO ledger_agent;


--
-- Name: SEQUENCE sync_run_seq_seq; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE ledger.sync_run_seq_seq TO ledger_agent;
GRANT SELECT,USAGE ON SEQUENCE ledger.sync_run_seq_seq TO ledger_console;


--
-- Name: TABLE ticket; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.ticket TO ledger_console;


--
-- Name: TABLE ticket_event; Type: ACL; Schema: ledger; Owner: -
--

REVOKE ALL ON TABLE ledger.ticket_event FROM ledger_owner;
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE ON TABLE ledger.ticket_event TO ledger_owner;
GRANT SELECT ON TABLE ledger.ticket_event TO ledger_console;


--
-- Name: TABLE ticket_pr; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.ticket_pr TO ledger_console;


--
-- Name: TABLE v_admin_history; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_admin_history TO ledger_console;


--
-- Name: TABLE v_agent; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_agent TO ledger_agent;
GRANT SELECT ON TABLE ledger.v_agent TO ledger_console;


--
-- Name: TABLE v_agent_demonstrated; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_agent_demonstrated TO ledger_agent;
GRANT SELECT ON TABLE ledger.v_agent_demonstrated TO ledger_console;


--
-- Name: TABLE v_agent_profile; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_agent_profile TO ledger_console;
GRANT SELECT ON TABLE ledger.v_agent_profile TO ledger_agent;


--
-- Name: TABLE v_board_freshness; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_board_freshness TO ledger_console;
GRANT SELECT ON TABLE ledger.v_board_freshness TO ledger_agent;


--
-- Name: TABLE v_claims; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_claims TO ledger_console;
GRANT SELECT ON TABLE ledger.v_claims TO ledger_agent;


--
-- Name: TABLE v_claim_without_a_live_owner; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_claim_without_a_live_owner TO ledger_console;
GRANT SELECT ON TABLE ledger.v_claim_without_a_live_owner TO ledger_agent;


--
-- Name: TABLE v_comment; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_comment TO ledger_console;
GRANT SELECT ON TABLE ledger.v_comment TO ledger_agent;


--
-- Name: TABLE v_drift_current; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_drift_current TO ledger_console;
GRANT SELECT ON TABLE ledger.v_drift_current TO ledger_agent;


--
-- Name: TABLE v_frontier; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_frontier TO ledger_agent;
GRANT SELECT ON TABLE ledger.v_frontier TO ledger_console;


--
-- Name: TABLE v_history; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_history TO ledger_agent;
GRANT SELECT ON TABLE ledger.v_history TO ledger_console;


--
-- Name: TABLE v_import_drift; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_import_drift TO ledger_agent;
GRANT SELECT ON TABLE ledger.v_import_drift TO ledger_console;


--
-- Name: TABLE v_import_drift_rows; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_import_drift_rows TO ledger_console;
GRANT SELECT ON TABLE ledger.v_import_drift_rows TO ledger_agent;


--
-- Name: TABLE v_legacy_import; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_legacy_import TO ledger_console;
GRANT SELECT ON TABLE ledger.v_legacy_import TO ledger_agent;


--
-- Name: TABLE v_mirror_refused; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_mirror_refused TO ledger_agent;
GRANT SELECT ON TABLE ledger.v_mirror_refused TO ledger_console;


--
-- Name: TABLE v_owner_blocked; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_owner_blocked TO ledger_agent;
GRANT SELECT ON TABLE ledger.v_owner_blocked TO ledger_console;


--
-- Name: TABLE v_owner_override_pending; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_owner_override_pending TO ledger_console;
GRANT SELECT ON TABLE ledger.v_owner_override_pending TO ledger_agent;


--
-- Name: TABLE v_park_without_owner; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_park_without_owner TO ledger_console;
GRANT SELECT ON TABLE ledger.v_park_without_owner TO ledger_agent;


--
-- Name: TABLE v_po_queue; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_po_queue TO ledger_console;
GRANT SELECT ON TABLE ledger.v_po_queue TO PUBLIC;


--
-- Name: TABLE v_request; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_request TO ledger_agent;
GRANT SELECT ON TABLE ledger.v_request TO ledger_console;


--
-- Name: TABLE v_request_summary; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_request_summary TO ledger_agent;
GRANT SELECT ON TABLE ledger.v_request_summary TO ledger_console;


--
-- Name: TABLE v_retired; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_retired TO ledger_console;
GRANT SELECT ON TABLE ledger.v_retired TO ledger_agent;


--
-- Name: TABLE v_session_entry; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_session_entry TO ledger_console;
GRANT SELECT ON TABLE ledger.v_session_entry TO ledger_agent;


--
-- Name: TABLE v_specialism; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_specialism TO ledger_console;
GRANT SELECT ON TABLE ledger.v_specialism TO ledger_agent;


--
-- Name: TABLE v_ticket; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_ticket TO ledger_console;
GRANT SELECT ON TABLE ledger.v_ticket TO ledger_agent;


--
-- Name: TABLE v_ticket_activity; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_ticket_activity TO ledger_console;


--
-- Name: TABLE v_ticket_detail; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_ticket_detail TO ledger_console;
GRANT SELECT ON TABLE ledger.v_ticket_detail TO ledger_agent;


--
-- Name: TABLE v_ticket_history; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_ticket_history TO ledger_console;


--
-- Name: TABLE v_ticket_list; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_ticket_list TO ledger_console;
GRANT SELECT ON TABLE ledger.v_ticket_list TO ledger_agent;
GRANT SELECT ON TABLE ledger.v_ticket_list TO PUBLIC;


--
-- Name: TABLE v_ticket_pr; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_ticket_pr TO ledger_console;
GRANT SELECT ON TABLE ledger.v_ticket_pr TO PUBLIC;


--
-- Name: TABLE v_ticket_requirement; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_ticket_requirement TO ledger_console;
GRANT SELECT ON TABLE ledger.v_ticket_requirement TO ledger_agent;


--
-- Name: TABLE v_ticket_status_counts; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_ticket_status_counts TO ledger_console;
GRANT SELECT ON TABLE ledger.v_ticket_status_counts TO ledger_agent;


--
-- Name: TABLE v_unreviewed_summary; Type: ACL; Schema: ledger; Owner: -
--

GRANT SELECT ON TABLE ledger.v_unreviewed_summary TO ledger_console;
GRANT SELECT ON TABLE ledger.v_unreviewed_summary TO ledger_agent;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: ledger; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE ledger_owner IN SCHEMA ledger GRANT SELECT ON TABLES TO ledger_console;


--
-- PostgreSQL database dump complete
--


