-- Phase 5b: approval, apply, promote, reset
USE ROLE GOV_ADMIN;

ALTER TABLE HACKATHON_DB.GOV.PENDING_FIXES ADD COLUMN IF NOT EXISTS approved_hash STRING;

-- Caller's rights: records the steward's CURRENT_USER() as approver
CREATE OR REPLACE PROCEDURE HACKATHON_DB.GOV.APPROVE_FIX(FIX_ID STRING)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  st STRING;
  cid STRING;
  h STRING;
  approver STRING;
BEGIN
  -- Only a named steward approves (LAB-05); the agent runs as the data owner and cannot reach this
  IF (CURRENT_ROLE() <> 'GOV_STEWARD') THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Only GOV_STEWARD may approve fixes');
  END IF;
  SELECT status, contract_id, SHA2(CONCAT_WS('|', fix_type, target_table, target_column, COALESCE(value, ''), template_id))
    INTO :st, :cid, :h FROM HACKATHON_DB.GOV.PENDING_FIXES WHERE fix_id = :FIX_ID;
  IF (st IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Unknown fix_id');
  END IF;
  IF (st <> 'PROPOSED') THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Only PROPOSED fixes can be approved; this fix is ' || st);
  END IF;
  approver := CURRENT_USER();
  UPDATE HACKATHON_DB.GOV.PENDING_FIXES
     SET status = 'APPROVED', approved_by = :approver, approved_at = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, approved_hash = :h
   WHERE fix_id = :FIX_ID AND status = 'PROPOSED' AND fix_hash = :h;
  IF (SQLROWCOUNT = 0) THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Fix changed since it was proposed (hash mismatch)');
  END IF;
  INSERT INTO HACKATHON_DB.GOV.AUDIT_LOG (actor, action, contract_id, fix_id, details, rule_version, agent_version, model)
    SELECT :approver, 'APPROVE_FIX', :cid, :FIX_ID, OBJECT_CONSTRUCT('approved_hash', :h, 'role', CURRENT_ROLE()), 'v1', 'v1', NULL;
  RETURN OBJECT_CONSTRUCT('status', 'OK', 'fix_id', :FIX_ID, 'approved_by', :approver);
END;
$$;

CREATE OR REPLACE PROCEDURE HACKATHON_DB.GOV.REJECT_FIX(FIX_ID STRING, REASON STRING)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
  st STRING;
  cid STRING;
  who STRING;
BEGIN
  IF (CURRENT_ROLE() <> 'GOV_STEWARD') THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Only GOV_STEWARD may reject fixes');
  END IF;
  SELECT status, contract_id INTO :st, :cid FROM HACKATHON_DB.GOV.PENDING_FIXES WHERE fix_id = :FIX_ID;
  IF (st IS NULL OR st NOT IN ('PROPOSED', 'NEEDS_OWNER_INPUT')) THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Only open fixes can be rejected');
  END IF;
  who := CURRENT_USER();
  UPDATE HACKATHON_DB.GOV.PENDING_FIXES SET status = 'REJECTED', reject_reason = :REASON,
         approved_by = :who, approved_at = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ WHERE fix_id = :FIX_ID;
  UPDATE HACKATHON_DB.GOV.CONTRACTS SET status = 'CHANGES_REQUESTED' WHERE contract_id = :cid;
  UPDATE HACKATHON_DB.GOV.CONTRACT_FIELDS SET status = 'CHANGES_REQUESTED' WHERE contract_id = :cid;
  INSERT INTO HACKATHON_DB.GOV.AUDIT_LOG (actor, action, contract_id, fix_id, details, rule_version, agent_version, model)
    SELECT :who, 'REJECT_FIX', :cid, :FIX_ID, OBJECT_CONSTRUCT('reason', :REASON), 'v1', 'v1', NULL;
  RETURN OBJECT_CONSTRUCT('status', 'OK', 'fix_id', :FIX_ID, 'contract_status', 'CHANGES_REQUESTED');
END;
$$;

-- Owner's rights: renders SQL only from FIX_TEMPLATES.SQL_STATEMENTS with validated values; never model-written SQL
CREATE OR REPLACE PROCEDURE HACKATHON_DB.GOV.APPLY_APPROVED_FIXES(FIX_ID STRING)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json
import re

IDENT_RE = re.compile(r"^[A-Z_][A-Z0-9_]*$")
EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")
BATCH_RE = re.compile(r"^[A-Z0-9-]{1,40}$")
CID_RE = re.compile(r"^[A-Z0-9-]{1,40}$")
PII_TYPES = {"patient_id", "email", "name"}

def q(session, sql, params=None):
    return session.sql(sql, params=params or []).collect()

def fail(session, fix_id, cid, msg):
    q(session, "INSERT INTO HACKATHON_DB.GOV.AUDIT_LOG (actor, action, contract_id, fix_id, details, rule_version, agent_version, model) "
               "SELECT CURRENT_USER(), 'APPLY_FAILED', ?, ?, PARSE_JSON(?), 'v1', 'v1', NULL", [cid, fix_id, json.dumps({"error": msg})])
    return {"status": "ERROR", "fix_id": fix_id, "message": msg}

def validate_value(template_id, column, value):
    if template_id == "T-OWNER":
        if not value or not EMAIL_RE.match(value): raise ValueError("owner must be an email")
        return value
    if template_id in ("T-SLA", "T-RETENTION"):
        return str(int(value))
    if template_id == "T-TAG-PII":
        if value not in PII_TYPES: raise ValueError("unknown PII type")
        return value
    if template_id == "T-QUARANTINE-BATCH":
        if not value or not BATCH_RE.match(value): raise ValueError("invalid batch id")
        return value
    return value or ""

def run(session, fix_id):
    rows = q(session, """SELECT p.*, SHA2(CONCAT_WS('|', fix_type, target_table, target_column, COALESCE(value, ''), template_id)) AS current_hash
                         FROM HACKATHON_DB.GOV.PENDING_FIXES p WHERE fix_id = ?""", [fix_id])
    if not rows:
        return {"status": "ERROR", "message": "Unknown fix_id"}
    p = rows[0]
    cid = p["CONTRACT_ID"]
    if p["STATUS"] != "APPROVED":
        return fail(session, fix_id, cid, f"Fix is {p['STATUS']}, not APPROVED")
    if not p["APPROVED_BY"]:
        return fail(session, fix_id, cid, "No named human approver")
    if not (p["CURRENT_HASH"] == p["FIX_HASH"] == p["APPROVED_HASH"]):
        return fail(session, fix_id, cid, "Fix hash does not match the approved fix")

    t = q(session, "SELECT sql_statements, undo_statements FROM HACKATHON_DB.GOV.FIX_TEMPLATES WHERE template_id = ?", [p["TEMPLATE_ID"]])
    if not t:
        return fail(session, fix_id, cid, "Template not found")
    stmts, undo = json.loads(t[0]["SQL_STATEMENTS"]), json.loads(t[0]["UNDO_STATEMENTS"])

    # Validate every placeholder value; identifiers must exist in INFORMATION_SCHEMA
    try:
        db, sch, tbl = p["TARGET_TABLE"].split(".")
        col = p["TARGET_COLUMN"]
        if not (db == "HACKATHON_DB" and sch in ("STAGING", "GOV") and IDENT_RE.match(tbl) and IDENT_RE.match(col)):
            raise ValueError("target outside allowed schemas")
        if not q(session, "SELECT 1 FROM HACKATHON_DB.INFORMATION_SCHEMA.COLUMNS WHERE table_schema = ? AND table_name = ? AND column_name = ?", [sch, tbl, col]):
            raise ValueError("target column does not exist")
        if not CID_RE.match(cid):
            raise ValueError("invalid contract id")
        val = validate_value(p["TEMPLATE_ID"], col, p["VALUE"]).replace("'", "''")
    except Exception as e:
        return fail(session, fix_id, cid, f"Validation failed: {e}")

    def render(s):
        return (s.replace("{table}", f"{db}.{sch}.{tbl}").replace("{column}", f'"{col}"')
                 .replace("{value}", val).replace("{contract_id}", cid))
    rendered, rendered_undo = [render(s) for s in stmts], [render(s) for s in undo]

    # Run the template's statements in order, in one transaction (the quarantine INSERT + DELETE commit together)
    try:
        q(session, "BEGIN")
        for s in rendered:
            q(session, s)
        if p["TEMPLATE_ID"] == "T-TAG-PII":
            # The template also marks the column pii: true in the parsed contract
            q(session, "UPDATE HACKATHON_DB.GOV.CONTRACT_FIELDS SET pii_columns = ARRAY_APPEND(COALESCE(pii_columns, ARRAY_CONSTRUCT()), ?) "
                       "WHERE contract_id = ? AND NOT ARRAY_CONTAINS(?::VARIANT, COALESCE(pii_columns, ARRAY_CONSTRUCT()))", [col, cid, col])
        q(session, "UPDATE HACKATHON_DB.GOV.PENDING_FIXES SET status = 'APPLIED', applied_at = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, "
                   "undo_statements = PARSE_JSON(?) WHERE fix_id = ?", [json.dumps(rendered_undo), fix_id])
        q(session, "INSERT INTO HACKATHON_DB.GOV.AUDIT_LOG (actor, action, contract_id, fix_id, details, rule_version, agent_version, model) "
                   "SELECT ?, 'APPLY_FIX', ?, ?, PARSE_JSON(?), 'v1', 'v1', NULL",
          [p["APPROVED_BY"], cid, fix_id, json.dumps({"template_id": p["TEMPLATE_ID"], "statements": rendered,
                                                     "undo_statements": rendered_undo, "applied_by_session_user": None})])
        q(session, "COMMIT")
    except Exception as e:
        q(session, "ROLLBACK")
        return fail(session, fix_id, cid, f"Apply failed and was rolled back: {e}")

    remaining = q(session, "SELECT COUNT(*) AS n FROM HACKATHON_DB.GOV.PENDING_FIXES WHERE contract_id = ? AND status <> 'APPLIED'", [cid])[0]["N"]
    if remaining == 0:
        q(session, "UPDATE HACKATHON_DB.GOV.CONTRACTS SET status = 'FIXES_APPLIED' WHERE contract_id = ?", [cid])
    return {"status": "OK", "fix_id": fix_id, "template_id": p["TEMPLATE_ID"], "approved_by": p["APPROVED_BY"],
            "statements_run": len(rendered), "open_fixes_for_contract": remaining}
$$;

-- Owner's rights: promote with CLONE (keeps masking policies and tags), keep prior PROD version
CREATE OR REPLACE PROCEDURE HACKATHON_DB.GOV.PROMOTE_DATASET(CONTRACT_ID STRING)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  src STRING;
  tbl STRING;
  prod STRING;
  open_fixes NUMBER;
  total_fixes NUMBER;
  had_prod BOOLEAN;
  approvers ARRAY;
BEGIN
  SELECT table_name INTO :src FROM HACKATHON_DB.GOV.CONTRACTS WHERE contract_id = :CONTRACT_ID;
  IF (src IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Unknown contract');
  END IF;
  SELECT COUNT(*), COUNT_IF(status <> 'APPLIED' OR approved_by IS NULL) INTO :total_fixes, :open_fixes
    FROM HACKATHON_DB.GOV.PENDING_FIXES WHERE contract_id = :CONTRACT_ID;
  IF (total_fixes = 0 OR open_fixes > 0) THEN
    INSERT INTO HACKATHON_DB.GOV.AUDIT_LOG (actor, action, contract_id, details, rule_version, agent_version, model)
      SELECT CURRENT_USER(), 'PROMOTE_BLOCKED', :CONTRACT_ID, OBJECT_CONSTRUCT('open_fixes', :open_fixes, 'total_fixes', :total_fixes), 'v1', 'v1', NULL;
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Every fix must be approved and applied before promotion',
                            'open_fixes', :open_fixes, 'total_fixes', :total_fixes);
  END IF;

  tbl := UPPER(SPLIT_PART(:src, '.', -1));
  IF (NOT EXISTS (SELECT 1 FROM HACKATHON_DB.INFORMATION_SCHEMA.TABLES WHERE table_schema = 'STAGING' AND table_name = :tbl)) THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Source table not in STAGING');
  END IF;
  src := 'HACKATHON_DB.STAGING.' || tbl;
  prod := 'HACKATHON_DB.PROD.' || tbl;

  -- Keep the prior production version so promotion can be rolled back
  SELECT COUNT(*) > 0 INTO :had_prod FROM HACKATHON_DB.INFORMATION_SCHEMA.TABLES WHERE table_schema = 'PROD' AND table_name = :tbl;
  IF (had_prod) THEN
    EXECUTE IMMEDIATE 'CREATE OR REPLACE TABLE ' || prod || '__PREV CLONE ' || prod;
  END IF;
  -- CLONE keeps masking policies and tags (CTAS would drop them); grants do not carry over
  EXECUTE IMMEDIATE 'CREATE OR REPLACE TABLE ' || prod || ' CLONE ' || src;
  EXECUTE IMMEDIATE 'GRANT SELECT ON TABLE ' || prod || ' TO ROLE GOV_CONSUMER';

  SELECT ARRAY_AGG(DISTINCT approved_by) INTO :approvers FROM HACKATHON_DB.GOV.PENDING_FIXES WHERE contract_id = :CONTRACT_ID;
  UPDATE HACKATHON_DB.GOV.CONTRACTS SET status = 'PROMOTED' WHERE contract_id = :CONTRACT_ID;
  UPDATE HACKATHON_DB.GOV.CONTRACT_FIELDS SET status = 'PROMOTED' WHERE contract_id = :CONTRACT_ID;
  INSERT INTO HACKATHON_DB.GOV.AUDIT_LOG (actor, action, contract_id, details, rule_version, agent_version, model)
    SELECT CURRENT_USER(), 'PROMOTE_DATASET', :CONTRACT_ID,
           OBJECT_CONSTRUCT('source', :src, 'target', :prod, 'previous_version_kept', :had_prod, 'fix_approvers', :approvers), 'v1', 'v1', NULL;
  RETURN OBJECT_CONSTRUCT('status', 'OK', 'contract_id', :CONTRACT_ID, 'promoted_to', :prod, 'previous_version_kept', :had_prod);
EXCEPTION
  WHEN OTHER THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM);
END;
$$;

-- GOV_ADMIN only: undo applied fixes in reverse apply order, keep AUDIT_LOG and append a RESET row
CREATE OR REPLACE PROCEDURE HACKATHON_DB.GOV.RESET_DEMO()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json

def q(session, sql, params=None):
    return session.sql(sql, params=params or []).collect()

def run(session):
    # Undo applied fixes in reverse apply order; each fix's undo statements run in their logged order
    applied = q(session, "SELECT fix_id, undo_statements FROM HACKATHON_DB.GOV.PENDING_FIXES "
                         "WHERE status = 'APPLIED' AND undo_statements IS NOT NULL ORDER BY applied_at DESC, fix_id DESC")
    undone, errors = [], []
    for r in applied:
        try:
            q(session, "BEGIN")
            for s in json.loads(r["UNDO_STATEMENTS"]):
                q(session, s)
            q(session, "COMMIT")
            undone.append(r["FIX_ID"])
        except Exception as e:
            q(session, "ROLLBACK")
            errors.append({"fix_id": r["FIX_ID"], "error": str(e)})

    dropped = []
    for t in q(session, "SELECT table_name FROM HACKATHON_DB.INFORMATION_SCHEMA.TABLES WHERE table_schema = 'PROD' AND table_type = 'BASE TABLE'"):
        q(session, f'DROP TABLE IF EXISTS HACKATHON_DB.PROD."{t["TABLE_NAME"]}"')
        dropped.append(t["TABLE_NAME"])

    q(session, "DELETE FROM HACKATHON_DB.GOV.PENDING_FIXES")
    q(session, "CREATE TABLE IF NOT EXISTS HACKATHON_DB.GOV.FIX_VERIFICATION (fix_id STRING)")
    q(session, "DELETE FROM HACKATHON_DB.GOV.FIX_VERIFICATION")
    q(session, "DELETE FROM HACKATHON_DB.GOV.CONTRACT_FIELDS")
    q(session, "UPDATE HACKATHON_DB.GOV.CONTRACTS SET status = 'SUBMITTED'")
    details = {"undone_fixes": undone, "undo_errors": errors, "dropped_prod_tables": dropped}
    q(session, "INSERT INTO HACKATHON_DB.GOV.AUDIT_LOG (actor, action, details, rule_version, agent_version, model) "
               "SELECT CURRENT_USER(), 'RESET', PARSE_JSON(?), 'v1', 'v1', NULL", [json.dumps(details)])
    return {"status": "OK" if not errors else "PARTIAL", **details}
$$;

-- Grants: steward approves/rejects (caller's rights needs table privileges), applies and promotes.
-- GOV_DATA_OWNER gets none of these; RESET_DEMO stays with GOV_ADMIN (owner).
GRANT SELECT, UPDATE ON TABLE HACKATHON_DB.GOV.PENDING_FIXES TO ROLE GOV_STEWARD;
GRANT SELECT, UPDATE ON TABLE HACKATHON_DB.GOV.CONTRACT_FIELDS TO ROLE GOV_STEWARD;
GRANT SELECT, UPDATE ON TABLE HACKATHON_DB.GOV.CONTRACTS TO ROLE GOV_STEWARD;
GRANT SELECT, INSERT ON TABLE HACKATHON_DB.GOV.AUDIT_LOG TO ROLE GOV_STEWARD;
GRANT USAGE ON PROCEDURE HACKATHON_DB.GOV.APPROVE_FIX(STRING) TO ROLE GOV_STEWARD;
GRANT USAGE ON PROCEDURE HACKATHON_DB.GOV.REJECT_FIX(STRING, STRING) TO ROLE GOV_STEWARD;
GRANT USAGE ON PROCEDURE HACKATHON_DB.GOV.APPLY_APPROVED_FIXES(STRING) TO ROLE GOV_STEWARD;
GRANT USAGE ON PROCEDURE HACKATHON_DB.GOV.PROMOTE_DATASET(STRING) TO ROLE GOV_STEWARD;
-- Consumer: reads LAB_RESULTS (masking demo) and PROD (PROMOTE_DATASET grants SELECT per promoted table)
GRANT USAGE ON SCHEMA HACKATHON_DB.PROD TO ROLE GOV_CONSUMER;
GRANT USAGE ON SCHEMA HACKATHON_DB.STAGING TO ROLE GOV_CONSUMER;
GRANT SELECT ON TABLE HACKATHON_DB.STAGING.LAB_RESULTS TO ROLE GOV_CONSUMER;
