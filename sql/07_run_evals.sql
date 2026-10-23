-- Phase 7: RUN_EVALS - score the review procedures (not the chat agent) against EVAL_SET
USE ROLE GOV_ADMIN;

CREATE TABLE IF NOT EXISTS HACKATHON_DB.GOV.EVAL_RESULTS (
  run_id STRING, contract_id STRING, expected_track STRING, actual_track STRING, track_ok BOOLEAN,
  expected_gaps ARRAY, actual_gaps ARRAY, missed_gaps ARRAY, extra_gaps ARRAY,
  recall FLOAT, precision FLOAT, review_status STRING, error STRING, scored_at TIMESTAMP_NTZ);

CREATE OR REPLACE PROCEDURE HACKATHON_DB.GOV.RUN_EVALS(SCOPE STRING DEFAULT 'MVP')
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json
import uuid

def q(session, sql, params=None):
    return session.sql(sql, params=params or []).collect()

def as_obj(v):
    return json.loads(v) if isinstance(v, str) else (v or {})

def run(session, scope):
    # Never overwrite a live demo: PROPOSE_FIXES replaces a contract's open fixes
    live = q(session, "SELECT COUNT(*) AS n FROM HACKATHON_DB.GOV.PENDING_FIXES WHERE run_id IS NULL")[0]["N"]
    if live:
        return {"status": "ERROR", "message": f"{live} live fixes in the approval queue; run RESET_DEMO or finish the demo first"}

    run_id = "EVAL-" + uuid.uuid4().hex[:8].upper()
    where = "" if (scope or "MVP").upper() == "ALL" else "WHERE e.in_mvp"
    cases = q(session, f"""SELECT e.contract_id, e.expected_track, e.expected_gaps, c.table_name
                           FROM HACKATHON_DB.GOV.EVAL_SET e JOIN HACKATHON_DB.GOV.CONTRACTS c USING (contract_id)
                           {where} ORDER BY e.contract_id""")
    rows = []
    for c in cases:
        cid, table = c["CONTRACT_ID"], c["TABLE_NAME"]
        expected = set(json.loads(c["EXPECTED_GAPS"] or "[]"))
        track, actual, status, err = None, set(), None, None
        try:
            # Same run order as every review
            for proc, arg in [("PARSE_CONTRACT", cid), ("PROFILE_COLUMNS", table), ("CLASSIFY_TRACK", cid), ("CHECK_PROVENANCE", table)]:
                r = as_obj(session.call(f"HACKATHON_DB.GOV.{proc}", arg))
                if r.get("status") not in (None, "OK"):
                    raise RuntimeError(f"{proc}: {r.get('error') or r.get('message')}")
                if proc == "CLASSIFY_TRACK":
                    track = r.get("track")
            r = as_obj(session.call("HACKATHON_DB.GOV.PROPOSE_FIXES", cid, None, run_id))
            status = r.get("contract_status") or r.get("status")
            if r.get("status") != "OK":
                raise RuntimeError(f"PROPOSE_FIXES: {r.get('error')}")
            actual = {g["rule_id"] for g in r.get("gaps", [])}
        except Exception as e:
            err = str(e)[:500]
        hit = expected & actual
        recall = 1.0 if not expected else len(hit) / len(expected)
        precision = 1.0 if not actual else len(hit) / len(actual)
        row = {"contract_id": cid, "expected_track": c["EXPECTED_TRACK"], "actual_track": track,
               "track_ok": track == c["EXPECTED_TRACK"], "expected_gaps": sorted(expected), "actual_gaps": sorted(actual),
               "missed_gaps": sorted(expected - actual), "extra_gaps": sorted(actual - expected),
               "recall": recall, "precision": precision, "review_status": status, "error": err}
        rows.append(row)
        q(session, """INSERT INTO HACKATHON_DB.GOV.EVAL_RESULTS
                      SELECT ?, ?, ?, ?, ?, PARSE_JSON(?), PARSE_JSON(?), PARSE_JSON(?), PARSE_JSON(?), ?, ?, ?, ?,
                             CURRENT_TIMESTAMP()::TIMESTAMP_NTZ""",
          [run_id, cid, row["expected_track"], track, row["track_ok"], json.dumps(row["expected_gaps"]),
           json.dumps(row["actual_gaps"]), json.dumps(row["missed_gaps"]), json.dumps(row["extra_gaps"]),
           recall, precision, status, err])

    # Clean up so the approval queue and status cards are untouched by the eval
    ids = [r["contract_id"] for r in rows]
    q(session, "DELETE FROM HACKATHON_DB.GOV.PENDING_FIXES WHERE run_id = ?", [run_id])
    if ids:
        marks = ", ".join(["?"] * len(ids))
        q(session, f"DELETE FROM HACKATHON_DB.GOV.CONTRACT_FIELDS WHERE contract_id IN ({marks})", ids)
        q(session, f"UPDATE HACKATHON_DB.GOV.CONTRACTS SET status = 'SUBMITTED' WHERE contract_id IN ({marks})", ids)

    n = len(rows) or 1
    summary = {"run_id": run_id, "scope": (scope or "MVP").upper(), "contracts": len(rows),
               "routing_accuracy": sum(r["track_ok"] for r in rows) / n,
               "gap_recall": sum(r["recall"] for r in rows) / n,
               "gap_precision": sum(r["precision"] for r in rows) / n,
               "errors": sum(1 for r in rows if r["error"])}
    q(session, "INSERT INTO HACKATHON_DB.GOV.AUDIT_LOG (actor, action, details, rule_version, agent_version, model, run_id) "
               "SELECT CURRENT_USER(), 'EVAL_RUN', PARSE_JSON(?), 'v1', 'v1', NULL, ?", [json.dumps(summary), run_id])
    return {"status": "OK", **summary, "results": rows}
$$;

-- Check: scores, then confirm the approval queue is empty and the contracts are back to SUBMITTED
CALL HACKATHON_DB.GOV.RUN_EVALS();
SELECT contract_id, expected_track, actual_track, track_ok, expected_gaps, actual_gaps, missed_gaps, extra_gaps, recall, precision, error
FROM HACKATHON_DB.GOV.EVAL_RESULTS
WHERE run_id = (SELECT MAX_BY(run_id, scored_at) FROM HACKATHON_DB.GOV.EVAL_RESULTS) ORDER BY contract_id;
SELECT COUNT(*) AS pending_fixes FROM HACKATHON_DB.GOV.PENDING_FIXES;
SELECT COUNT_IF(status <> 'SUBMITTED') AS non_submitted FROM HACKATHON_DB.GOV.CONTRACTS;

-- Full set including red-team / edge contracts (C-FIN-002, C-LAB-DGR track-downgrade, C-LAB-INJ prompt injection)
CALL HACKATHON_DB.GOV.RUN_EVALS('ALL');

-- Results (14:20): MVP run EVAL-11236BC9 and ALL run - routing 100%, gap recall 100%, gap precision 100%, 0 errors.
-- C-LAB-INJ: YAML asks for STANDARD and auto-approval; routed REGULATED_LAB with LAB-01 + LAB-04 (deterministic, YAML is data).
-- C-LAB-DGR: declared domain sales; escalated to REGULATED_LAB; status BLOCKED (LAB-01 gap needs a contract change, no template).
