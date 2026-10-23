-- Phase 4a: column profiles (counts and pattern rates only, never raw values)
USE ROLE GOV_ADMIN;

CREATE TABLE IF NOT EXISTS HACKATHON_DB.GOV.COLUMN_PROFILES (
  table_name          STRING,
  column_name         STRING,
  data_type           STRING,
  row_count           NUMBER,
  null_count          NUMBER,
  distinct_count      NUMBER,
  phi_pattern_rate    FLOAT,    -- share of values that look like patient IDs (PT-<digits>)
  email_pattern_rate  FLOAT,    -- share of values that look like email addresses
  has_masking_policy  BOOLEAN,
  pii_tag             STRING,   -- value of HACKATHON_DB.GOV.PII_TYPE, if set
  profiled_at         TIMESTAMP_NTZ
);

CREATE OR REPLACE PROCEDURE HACKATHON_DB.GOV.PROFILE_COLUMNS(TABLE_NAME STRING)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  fq STRING;
  tbl STRING;
  n_cols NUMBER DEFAULT 0;
  c CURSOR FOR SELECT column_name, data_type
               FROM HACKATHON_DB.INFORMATION_SCHEMA.COLUMNS
               WHERE table_schema = 'STAGING' AND table_name = ?
               ORDER BY ordinal_position;
BEGIN
  -- Accept only a real STAGING table; the name is data, not SQL
  tbl := UPPER(SPLIT_PART(:TABLE_NAME, '.', -1));
  IF (NOT EXISTS (SELECT 1 FROM HACKATHON_DB.INFORMATION_SCHEMA.TABLES
                  WHERE table_schema = 'STAGING' AND table_name = :tbl)) THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Unknown STAGING table');
  END IF;
  fq := 'HACKATHON_DB.STAGING.' || tbl;

  DELETE FROM HACKATHON_DB.GOV.COLUMN_PROFILES WHERE table_name = :fq;

  OPEN c USING (tbl);
  FOR rec IN c DO
    LET col STRING := rec.column_name;
    LET dt STRING := rec.data_type;
    LET q STRING := 'INSERT INTO HACKATHON_DB.GOV.COLUMN_PROFILES ' ||
      '(table_name, column_name, data_type, row_count, null_count, distinct_count, phi_pattern_rate, email_pattern_rate, profiled_at) ' ||
      'SELECT ''' || fq || ''', ''' || col || ''', ''' || dt || ''', COUNT(*), COUNT_IF("' || col || '" IS NULL), ' ||
      'COUNT(DISTINCT "' || col || '"), ' ||
      'IFF(COUNT(*) = 0, 0, COUNT_IF(REGEXP_LIKE("' || col || '"::STRING, ''PT-[0-9]{4,}'')) / COUNT(*)), ' ||
      'IFF(COUNT(*) = 0, 0, COUNT_IF(REGEXP_LIKE("' || col || '"::STRING, ''[^@ ]+@[^@ ]+\\.[A-Za-z]+'')) / COUNT(*)), ' ||
      'CURRENT_TIMESTAMP()::TIMESTAMP_NTZ FROM ' || fq;
    EXECUTE IMMEDIATE :q;
    n_cols := n_cols + 1;
  END FOR;

  -- Masking policies and PII tags attached to columns
  UPDATE HACKATHON_DB.GOV.COLUMN_PROFILES p
     SET has_masking_policy = EXISTS (
           SELECT 1 FROM TABLE(HACKATHON_DB.INFORMATION_SCHEMA.POLICY_REFERENCES(
                    REF_ENTITY_NAME => :fq, REF_ENTITY_DOMAIN => 'table')) r
           WHERE r.policy_kind = 'MASKING_POLICY' AND r.ref_column_name = p.column_name)
   WHERE p.table_name = :fq;

  UPDATE HACKATHON_DB.GOV.COLUMN_PROFILES p
     SET pii_tag = t.tag_value
    FROM TABLE(HACKATHON_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(:fq, 'table')) t
   WHERE p.table_name = :fq AND t.tag_name = 'PII_TYPE' AND t.column_name = p.column_name;

  RETURN OBJECT_CONSTRUCT('status', 'OK', 'table', fq, 'columns_profiled', n_cols);
EXCEPTION
  WHEN OTHER THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM);
END;
$$;

CALL HACKATHON_DB.GOV.PROFILE_COLUMNS('HACKATHON_DB.STAGING.LAB_RESULTS');
CALL HACKATHON_DB.GOV.PROFILE_COLUMNS('HACKATHON_DB.STAGING.LAB_RESULTS_SITE_B');
CALL HACKATHON_DB.GOV.PROFILE_COLUMNS('HACKATHON_DB.STAGING.SALES_ORDERS');
CALL HACKATHON_DB.GOV.PROFILE_COLUMNS('HACKATHON_DB.STAGING.FINANCE_GL');

-- Check: LAB_RESULTS.patient_id ~100% PHI pattern, no masking policy (gap); SITE_B masked and tagged
SELECT table_name, column_name, row_count, phi_pattern_rate, email_pattern_rate, has_masking_policy, pii_tag
FROM HACKATHON_DB.GOV.COLUMN_PROFILES
WHERE phi_pattern_rate > 0 OR email_pattern_rate > 0 OR has_masking_policy OR pii_tag IS NOT NULL
ORDER BY 1, 2;
