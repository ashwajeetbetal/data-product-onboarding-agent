-- Hardening after the 15:10 rehearsal (a C-LAB-INJ reject never registered; C-LAB-INJ was promoted twice).
-- Full procedure bodies replace the ones in 05b_approval_apply_promote_reset.sql.
-- 1) REJECT_FIX: every refused reject (wrong role, unknown or closed fix, empty reason) writes a REJECT_FAILED row.
-- 2) PROMOTE_DATASET: idempotent. An already-PROMOTED contract returns already_promoted; the status is claimed
--    before cloning, so a second concurrent call stops instead of cloning again; any error sets BLOCKED.
-- The app-only "hide Approve for test contracts" change was tried and reverted at the user's request.
USE ROLE GOV_ADMIN;

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
  msg STRING;
BEGIN
  who := CURRENT_USER();
  SELECT status, contract_id INTO :st, :cid FROM HACKATHON_DB.GOV.PENDING_FIXES WHERE fix_id = :FIX_ID;
  IF (CURRENT_ROLE() <> 'GOV_STEWARD') THEN
    msg := 'Only GOV_STEWARD may reject fixes';
  ELSEIF (st IS NULL) THEN
    msg := 'Unknown fix_id';
  ELSEIF (st NOT IN ('PROPOSED', 'NEEDS_OWNER_INPUT')) THEN
    msg := 'Only open fixes can be rejected; this fix is ' || st;
  ELSEIF (REASON IS NULL OR TRIM(REASON) = '') THEN
    msg := 'A reason is required';
  END IF;
  IF (msg IS NOT NULL) THEN
    -- A misfired reject is visible in the audit trail
    INSERT INTO HACKATHON_DB.GOV.AUDIT_LOG (actor, action, contract_id, fix_id, details, rule_version, agent_version, model)
      SELECT :who, 'REJECT_FAILED', :cid, :FIX_ID, OBJECT_CONSTRUCT('error', :msg, 'role', CURRENT_ROLE()), 'v1', 'v1', NULL;
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', :msg);
  END IF;
  UPDATE HACKATHON_DB.GOV.PENDING_FIXES SET status = 'REJECTED', reject_reason = :REASON,
         approved_by = :who, approved_at = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ WHERE fix_id = :FIX_ID;
  UPDATE HACKATHON_DB.GOV.CONTRACTS SET status = 'CHANGES_REQUESTED' WHERE contract_id = :cid;
  UPDATE HACKATHON_DB.GOV.CONTRACT_FIELDS SET status = 'CHANGES_REQUESTED' WHERE contract_id = :cid;
  INSERT INTO HACKATHON_DB.GOV.AUDIT_LOG (actor, action, contract_id, fix_id, details, rule_version, agent_version, model)
    SELECT :who, 'REJECT_FIX', :cid, :FIX_ID, OBJECT_CONSTRUCT('reason', :REASON, 'role', CURRENT_ROLE()), 'v1', 'v1', NULL;
  RETURN OBJECT_CONSTRUCT('status', 'OK', 'fix_id', :FIX_ID, 'rejected_by', :who, 'contract_status', 'CHANGES_REQUESTED');
END;
$$;

CREATE OR REPLACE PROCEDURE HACKATHON_DB.GOV.PROMOTE_DATASET(CONTRACT_ID STRING)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  src STRING;
  cstatus STRING;
  tbl STRING;
  prod STRING;
  open_fixes NUMBER;
  total_fixes NUMBER;
  had_prod BOOLEAN;
  approvers ARRAY;
BEGIN
  SELECT table_name, status INTO :src, :cstatus FROM HACKATHON_DB.GOV.CONTRACTS WHERE contract_id = :CONTRACT_ID;
  IF (src IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Unknown contract');
  END IF;
  -- Idempotent: a second click (or a second caller) must not clone over the promoted table again
  IF (cstatus = 'PROMOTED') THEN
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'contract_id', :CONTRACT_ID, 'already_promoted', TRUE,
                            'promoted_to', 'HACKATHON_DB.PROD.' || UPPER(SPLIT_PART(:src, '.', -1)));
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

  -- Claim the promotion first so a concurrent call sees PROMOTED and stops
  UPDATE HACKATHON_DB.GOV.CONTRACTS SET status = 'PROMOTED' WHERE contract_id = :CONTRACT_ID AND status <> 'PROMOTED';
  IF (SQLROWCOUNT = 0) THEN
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'contract_id', :CONTRACT_ID, 'already_promoted', TRUE, 'promoted_to', :prod);
  END IF;

  -- Keep the prior production version so promotion can be rolled back
  SELECT COUNT(*) > 0 INTO :had_prod FROM HACKATHON_DB.INFORMATION_SCHEMA.TABLES WHERE table_schema = 'PROD' AND table_name = :tbl;
  IF (had_prod) THEN
    EXECUTE IMMEDIATE 'CREATE OR REPLACE TABLE ' || prod || '__PREV CLONE ' || prod;
  END IF;
  -- CLONE keeps masking policies and tags (CTAS would drop them); grants do not carry over
  EXECUTE IMMEDIATE 'CREATE OR REPLACE TABLE ' || prod || ' CLONE ' || src;
  EXECUTE IMMEDIATE 'GRANT SELECT ON TABLE ' || prod || ' TO ROLE GOV_CONSUMER';

  SELECT ARRAY_AGG(DISTINCT approved_by) INTO :approvers FROM HACKATHON_DB.GOV.PENDING_FIXES WHERE contract_id = :CONTRACT_ID;
  UPDATE HACKATHON_DB.GOV.CONTRACT_FIELDS SET status = 'PROMOTED' WHERE contract_id = :CONTRACT_ID;
  INSERT INTO HACKATHON_DB.GOV.AUDIT_LOG (actor, action, contract_id, details, rule_version, agent_version, model)
    SELECT CURRENT_USER(), 'PROMOTE_DATASET', :CONTRACT_ID,
           OBJECT_CONSTRUCT('source', :src, 'target', :prod, 'previous_version_kept', :had_prod, 'fix_approvers', :approvers), 'v1', 'v1', NULL;
  RETURN OBJECT_CONSTRUCT('status', 'OK', 'contract_id', :CONTRACT_ID, 'promoted_to', :prod, 'previous_version_kept', :had_prod);
EXCEPTION
  WHEN OTHER THEN
    UPDATE HACKATHON_DB.GOV.CONTRACTS SET status = 'BLOCKED' WHERE contract_id = :CONTRACT_ID;
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM);
END;
$$;

-- CREATE OR REPLACE drops grants, including the app's caller grants: re-grant both
GRANT USAGE ON PROCEDURE HACKATHON_DB.GOV.REJECT_FIX(STRING, STRING) TO ROLE GOV_STEWARD;
GRANT USAGE ON PROCEDURE HACKATHON_DB.GOV.PROMOTE_DATASET(STRING) TO ROLE GOV_STEWARD;
USE ROLE ACCOUNTADMIN;
GRANT CALLER USAGE ON PROCEDURE HACKATHON_DB.GOV.REJECT_FIX(STRING, STRING) TO ROLE GOV_ADMIN;
GRANT CALLER USAGE ON PROCEDURE HACKATHON_DB.GOV.PROMOTE_DATASET(STRING) TO ROLE GOV_ADMIN;
USE ROLE GOV_ADMIN;

-- Checks (15:24, as GOV_STEWARD after seeding C-LAB-INJ fixes):
--   REJECT_FIX('FX-41F918D9C1', '')        -> ERROR, REJECT_FAILED row "A reason is required"
--   REJECT_FIX('FX-41F918D9C1', '<reason>') -> OK, REJECT_FIX row, C-LAB-INJ = CHANGES_REQUESTED
--   PROMOTE_DATASET on a PROMOTED contract  -> already_promoted = TRUE, no PROD table created
CALL HACKATHON_DB.GOV.RESET_DEMO();
