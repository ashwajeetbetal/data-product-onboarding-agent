-- Phase 5a: review tables and procedures (PARSE_CONTRACT, CLASSIFY_TRACK, CHECK_PROVENANCE).
-- PROFILE_COLUMNS is in 04a_column_profiles.sql; PROPOSE_FIXES is in 05a_propose_fixes.sql.
USE ROLE GOV_ADMIN;

-- Column names owner, freshness_sla_hours, retention_days match the FIX_TEMPLATES UPDATE statements exactly
CREATE TABLE IF NOT EXISTS HACKATHON_DB.GOV.CONTRACT_FIELDS (
  contract_id STRING PRIMARY KEY, table_name STRING, domain STRING, owner STRING,
  freshness_sla_hours NUMBER, retention_days NUMBER, declared_source ARRAY, pii_columns ARRAY,
  columns VARIANT, track STRING, status STRING, parsed_at TIMESTAMP_NTZ);
CREATE TABLE IF NOT EXISTS HACKATHON_DB.GOV.PENDING_FIXES (
  fix_id STRING PRIMARY KEY, contract_id STRING, fix_type STRING, template_id STRING, rule_id STRING,
  target_table STRING, target_column STRING, value STRING, rationale STRING, fix_hash STRING, status STRING,
  approved_by STRING, approved_at TIMESTAMP_NTZ, applied_at TIMESTAMP_NTZ, undo_statements ARRAY,
  reject_reason STRING, run_id STRING, created_at TIMESTAMP_NTZ);
CREATE TABLE IF NOT EXISTS HACKATHON_DB.GOV.AUDIT_LOG (
  audit_id NUMBER AUTOINCREMENT, ts TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
  actor STRING, action STRING, contract_id STRING, fix_id STRING, details VARIANT,
  rule_version STRING, agent_version STRING, model STRING, run_id STRING);

CREATE OR REPLACE PROCEDURE HACKATHON_DB.GOV.PARSE_CONTRACT(CONTRACT_ID STRING)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'pyyaml')
HANDLER = 'run'
EXECUTE AS OWNER
AS
$$
import json
import yaml

ALLOWED_SOURCES = {"instrument", "human", "ai"}

def audit(session, cid, action, details):
    session.sql(
        "INSERT INTO HACKATHON_DB.GOV.AUDIT_LOG (actor, action, contract_id, details, rule_version, agent_version, model) "
        "SELECT CURRENT_USER(), ?, ?, PARSE_JSON(?), 'v1', 'v1', NULL",
        params=[action, cid, json.dumps(details)]).collect()

def block(session, cid, msg):
    session.sql("UPDATE HACKATHON_DB.GOV.CONTRACTS SET status = 'BLOCKED' WHERE contract_id = ?", params=[cid]).collect()
    audit(session, cid, "PARSE_FAILED", {"error": msg})
    return {"status": "BLOCKED", "contract_id": cid, "error": msg}

def run(session, contract_id):
    rows = session.sql(
        "SELECT contract_id, table_name, yaml FROM HACKATHON_DB.GOV.CONTRACTS WHERE contract_id = ?",
        params=[contract_id]).collect()
    if not rows:
        return {"status": "ERROR", "error": "Unknown contract_id"}
    cid, table_name, text = rows[0]["CONTRACT_ID"], rows[0]["TABLE_NAME"], rows[0]["YAML"]
    try:
        doc = yaml.safe_load(text)          # contract text is data; safe_load never executes anything
        if not isinstance(doc, dict):
            raise ValueError("Contract YAML is not a mapping")
        cols = []
        for c in doc.get("columns") or []:
            if isinstance(c, dict) and c.get("name"):
                cols.append({"name": str(c["name"]).upper(), "type": str(c.get("type", "")),
                             "pii": c.get("pii") is True, "pii_type": c.get("pii_type")})
        src = doc.get("declared_source") or []
        src = [str(s).lower() for s in (src if isinstance(src, list) else [src])]
        def num(v):
            try:
                return int(v) if v is not None else None
            except (TypeError, ValueError):
                return None
        owner = doc.get("owner")
        fields = {
            "contract_id": cid,
            "table_name": table_name,
            "domain": str(doc.get("domain", "")).lower() or None,
            "owner": str(owner) if owner else None,
            "freshness_sla_hours": num(doc.get("freshness_sla_hours")),
            "retention_days": num(doc.get("retention_days")),
            "declared_source": [s for s in src if s in ALLOWED_SOURCES],
            "pii_columns": [c["name"] for c in cols if c["pii"]],
            "columns": cols,
        }
    except Exception as e:
        return block(session, cid, f"Contract could not be parsed: {e}")

    session.sql("""
        MERGE INTO HACKATHON_DB.GOV.CONTRACT_FIELDS t
        USING (SELECT PARSE_JSON(?) AS j) s ON t.contract_id = s.j:contract_id::STRING
        WHEN MATCHED THEN UPDATE SET table_name = s.j:table_name::STRING, domain = s.j:domain::STRING,
             owner = s.j:owner::STRING, freshness_sla_hours = s.j:freshness_sla_hours::NUMBER,
             retention_days = s.j:retention_days::NUMBER, declared_source = s.j:declared_source::ARRAY,
             pii_columns = s.j:pii_columns::ARRAY, columns = s.j:columns, track = NULL, status = 'PARSED',
             parsed_at = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
        WHEN NOT MATCHED THEN INSERT (contract_id, table_name, domain, owner, freshness_sla_hours, retention_days,
             declared_source, pii_columns, columns, track, status, parsed_at)
             VALUES (s.j:contract_id::STRING, s.j:table_name::STRING, s.j:domain::STRING, s.j:owner::STRING,
             s.j:freshness_sla_hours::NUMBER, s.j:retention_days::NUMBER, s.j:declared_source::ARRAY,
             s.j:pii_columns::ARRAY, s.j:columns, NULL, 'PARSED', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)
    """, params=[json.dumps(fields)]).collect()
    session.sql("UPDATE HACKATHON_DB.GOV.CONTRACTS SET status = 'IN_REVIEW' WHERE contract_id = ?", params=[cid]).collect()
    audit(session, cid, "PARSE_CONTRACT", {"owner_present": fields["owner"] is not None,
                                           "sla_present": fields["freshness_sla_hours"] is not None,
                                           "pii_columns": fields["pii_columns"]})
    return {"status": "OK", **{k: v for k, v in fields.items() if k != "columns"}}
$$;

CREATE OR REPLACE PROCEDURE HACKATHON_DB.GOV.CLASSIFY_TRACK(CONTRACT_ID STRING)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  tbl STRING;
  dom STRING;
  phi_signal BOOLEAN DEFAULT FALSE;
  fin_signal BOOLEAN DEFAULT FALSE;
  trk STRING;
  reasons ARRAY DEFAULT ARRAY_CONSTRUCT();
BEGIN
  SELECT table_name, domain INTO :tbl, :dom FROM HACKATHON_DB.GOV.CONTRACT_FIELDS WHERE contract_id = :CONTRACT_ID;
  IF (tbl IS NULL) THEN
    UPDATE HACKATHON_DB.GOV.CONTRACTS SET status = 'BLOCKED' WHERE contract_id = :CONTRACT_ID;
    RETURN OBJECT_CONSTRUCT('status', 'BLOCKED', 'error', 'Run PARSE_CONTRACT first');
  END IF;

  -- ROUTE-01: patient identifiers by column name or by value pattern, whatever the declared domain
  SELECT COUNT(*) > 0 INTO :phi_signal FROM HACKATHON_DB.GOV.COLUMN_PROFILES
   WHERE table_name = :tbl AND (phi_pattern_rate > 0.5 OR column_name ILIKE '%PATIENT%' OR column_name ILIKE '%SUBJECT_ID%');
  IF (NOT phi_signal) THEN
    SELECT COUNT(*) > 0 INTO :phi_signal FROM HACKATHON_DB.INFORMATION_SCHEMA.COLUMNS
     WHERE table_catalog || '.' || table_schema || '.' || table_name = :tbl
       AND (column_name ILIKE '%PATIENT%' OR column_name ILIKE '%SUBJECT_ID%');
  END IF;
  -- ROUTE-02: finance domain or general ledger table
  fin_signal := (dom = 'finance' OR tbl ILIKE '%FINANCE_GL%' OR tbl ILIKE '%LEDGER%');

  IF (phi_signal OR dom = 'lab') THEN
    trk := 'REGULATED_LAB';
    reasons := ARRAY_APPEND(reasons, IFF(phi_signal, 'ROUTE-01: patient identifiers found', 'domain lab'));
  ELSEIF (fin_signal) THEN
    trk := 'FINANCIAL';
    reasons := ARRAY_APPEND(reasons, 'ROUTE-02: finance data');
  ELSE
    trk := 'STANDARD';
    reasons := ARRAY_APPEND(reasons, 'ROUTE-03: default');
  END IF;

  UPDATE HACKATHON_DB.GOV.CONTRACT_FIELDS SET track = :trk, status = 'CLASSIFIED' WHERE contract_id = :CONTRACT_ID;
  INSERT INTO HACKATHON_DB.GOV.AUDIT_LOG (actor, action, contract_id, details, rule_version, agent_version, model)
    SELECT CURRENT_USER(), 'CLASSIFY_TRACK', :CONTRACT_ID,
           OBJECT_CONSTRUCT('track', :trk, 'declared_domain', :dom, 'reasons', :reasons), 'v1', 'v1', NULL;
  RETURN OBJECT_CONSTRUCT('status', 'OK', 'contract_id', :CONTRACT_ID, 'track', :trk, 'declared_domain', :dom, 'reasons', :reasons);
EXCEPTION
  WHEN OTHER THEN
    UPDATE HACKATHON_DB.GOV.CONTRACTS SET status = 'BLOCKED' WHERE contract_id = :CONTRACT_ID;
    RETURN OBJECT_CONSTRUCT('status', 'BLOCKED', 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE PROCEDURE HACKATHON_DB.GOV.CHECK_PROVENANCE(TABLE_NAME STRING)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  tbl STRING;
  fq STRING;
  declared ARRAY;
  cid STRING;
  mismatches ARRAY;
  unlogged NUMBER;
BEGIN
  tbl := UPPER(SPLIT_PART(:TABLE_NAME, '.', -1));
  IF (NOT EXISTS (SELECT 1 FROM HACKATHON_DB.INFORMATION_SCHEMA.TABLES
                  WHERE table_schema = 'STAGING' AND table_name = :tbl)) THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Unknown STAGING table');
  END IF;
  fq := 'HACKATHON_DB.STAGING.' || tbl;

  -- Declared source from the most recently parsed contract for this table
  SELECT contract_id, declared_source INTO :cid, :declared FROM HACKATHON_DB.GOV.CONTRACT_FIELDS
   WHERE table_name = :fq ORDER BY parsed_at DESC LIMIT 1;

  -- Batches present in the table, joined with WRITE_LOG (not ACCESS_HISTORY, which lags)
  LET q STRING := 'SELECT DISTINCT batch_id FROM ' || fq;
  LET rs RESULTSET := (EXECUTE IMMEDIATE :q);
  CREATE OR REPLACE TEMPORARY TABLE HACKATHON_DB.GOV.TMP_BATCHES AS SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

  SELECT ARRAY_AGG(OBJECT_CONSTRUCT('batch_id', w.batch_id, 'written_by', w.written_by,
                   'source_type', w.source_type, 'rows_written', w.rows_written))
    INTO :mismatches
    FROM HACKATHON_DB.GOV.TMP_BATCHES b
    JOIN HACKATHON_DB.GOV.WRITE_LOG w ON w.batch_id = b.batch_id AND w.table_name = :fq
   WHERE NOT ARRAY_CONTAINS(w.source_type::VARIANT, COALESCE(:declared, ARRAY_CONSTRUCT()));

  SELECT COUNT(*) INTO :unlogged FROM HACKATHON_DB.GOV.TMP_BATCHES b
   WHERE NOT EXISTS (SELECT 1 FROM HACKATHON_DB.GOV.WRITE_LOG w WHERE w.batch_id = b.batch_id AND w.table_name = :fq);

  INSERT INTO HACKATHON_DB.GOV.AUDIT_LOG (actor, action, contract_id, details, rule_version, agent_version, model)
    SELECT CURRENT_USER(), 'CHECK_PROVENANCE', :cid,
           OBJECT_CONSTRUCT('table', :fq, 'declared_source', :declared, 'mismatched_batches', :mismatches, 'unlogged_batches', :unlogged),
           'v1', 'v1', NULL;
  RETURN OBJECT_CONSTRUCT('status', 'OK', 'table', :fq, 'contract_id', :cid, 'declared_source', :declared,
                          'mismatched_batches', COALESCE(:mismatches, ARRAY_CONSTRUCT()), 'unlogged_batches', :unlogged);
EXCEPTION
  WHEN OTHER THEN
    RETURN OBJECT_CONSTRUCT('status', 'BLOCKED', 'error', SQLERRM);
END;
$$;

-- GOV_DATA_OWNER: the five review procedures only (never APPROVE/REJECT/APPLY/PROMOTE/RESET)
GRANT USAGE ON PROCEDURE HACKATHON_DB.GOV.PARSE_CONTRACT(STRING) TO ROLE GOV_DATA_OWNER;
GRANT USAGE ON PROCEDURE HACKATHON_DB.GOV.PROFILE_COLUMNS(STRING) TO ROLE GOV_DATA_OWNER;
GRANT USAGE ON PROCEDURE HACKATHON_DB.GOV.CLASSIFY_TRACK(STRING) TO ROLE GOV_DATA_OWNER;
GRANT USAGE ON PROCEDURE HACKATHON_DB.GOV.CHECK_PROVENANCE(STRING) TO ROLE GOV_DATA_OWNER;
GRANT USAGE ON PROCEDURE HACKATHON_DB.GOV.PROPOSE_FIXES(STRING, STRING, STRING) TO ROLE GOV_DATA_OWNER;

-- Checks ---------------------------------------------------------------------
-- C-LAB-DGR declares domain sales but holds patient IDs: expect REGULATED_LAB
CALL HACKATHON_DB.GOV.PARSE_CONTRACT('C-LAB-DGR');
CALL HACKATHON_DB.GOV.CLASSIFY_TRACK('C-LAB-DGR');

-- C-LAB-001 as GOV_DATA_OWNER, in review run order
USE SECONDARY ROLES NONE;
USE ROLE GOV_DATA_OWNER;
CALL HACKATHON_DB.GOV.PARSE_CONTRACT('C-LAB-001');
CALL HACKATHON_DB.GOV.PROFILE_COLUMNS('HACKATHON_DB.STAGING.LAB_RESULTS');
CALL HACKATHON_DB.GOV.CLASSIFY_TRACK('C-LAB-001');                              -- expect REGULATED_LAB
CALL HACKATHON_DB.GOV.CHECK_PROVENANCE('HACKATHON_DB.STAGING.LAB_RESULTS');     -- expect LAB-B010 / ai
CALL HACKATHON_DB.GOV.PROPOSE_FIXES('C-LAB-001');
-- expect gaps STD-01, STD-02, LAB-01, LAB-04; T-OWNER and T-SLA = NEEDS_OWNER_INPUT
CALL HACKATHON_DB.GOV.PROPOSE_FIXES('C-LAB-001', '{"owner": "lab.ops@example.com", "freshness_sla_hours": 24}');
-- expect T-OWNER and T-SLA = PROPOSED with the confirmed values
USE ROLE GOV_ADMIN;
SELECT fix_id, rule_id, template_id, target_column, value, status FROM HACKATHON_DB.GOV.PENDING_FIXES
WHERE contract_id = 'C-LAB-001' ORDER BY rule_id, template_id;
