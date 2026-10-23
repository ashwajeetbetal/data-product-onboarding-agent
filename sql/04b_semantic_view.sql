-- Phase 4b: governance semantic view over WRITE_LOG, CONTRACTS (no yaml) and COLUMN_PROFILES. No raw PHI.
USE ROLE GOV_ADMIN;

CREATE OR REPLACE SEMANTIC VIEW HACKATHON_DB.GOV.GOVERNANCE_SV
  TABLES (
    write_log AS HACKATHON_DB.GOV.WRITE_LOG PRIMARY KEY (batch_id)
      WITH SYNONYMS = ('batches', 'provenance', 'write history')
      COMMENT = 'One row per data batch written to a product table, with who wrote it and the source type (instrument, human or ai).',
    contracts AS HACKATHON_DB.GOV.CONTRACTS PRIMARY KEY (contract_id)
      WITH SYNONYMS = ('data contracts', 'submissions')
      COMMENT = 'Submitted data contracts and their review status. Contract text is excluded.',
    column_profiles AS HACKATHON_DB.GOV.COLUMN_PROFILES PRIMARY KEY (table_name, column_name)
      WITH SYNONYMS = ('profiles', 'column stats')
      COMMENT = 'Column statistics and PHI/email pattern rates; never raw values.'
  )
  FACTS (
    write_log.rows_written AS rows_written COMMENT = 'Rows written in the batch',
    column_profiles.row_count AS row_count,
    column_profiles.null_count AS null_count,
    column_profiles.distinct_count AS distinct_count,
    column_profiles.phi_pattern_rate AS phi_pattern_rate COMMENT = 'Share of values that look like patient IDs',
    column_profiles.email_pattern_rate AS email_pattern_rate COMMENT = 'Share of values that look like email addresses'
  )
  DIMENSIONS (
    write_log.batch_id AS batch_id COMMENT = 'Batch identifier, e.g. LAB-B010',
    write_log.table_name AS table_name COMMENT = 'Fully qualified table the batch was written to, e.g. HACKATHON_DB.STAGING.LAB_RESULTS',
    write_log.written_by AS written_by WITH SYNONYMS = ('writer', 'service account', 'author') COMMENT = 'User or service account that wrote the batch',
    write_log.source_type AS source_type WITH SYNONYMS = ('source', 'origin') COMMENT = 'instrument, human or ai. ai means written by an AI service account.',
    write_log.written_at AS written_at,
    contracts.contract_id AS contract_id,
    contracts.contract_table AS table_name COMMENT = 'Table the contract covers',
    contracts.submitted_by AS submitted_by,
    contracts.status AS status COMMENT = 'Contract review status, e.g. SUBMITTED, BLOCKED, APPROVED, PROMOTED',
    contracts.is_test AS is_test COMMENT = 'TRUE for eval and injection-test contracts',
    contracts.submitted_at AS submitted_at,
    column_profiles.profiled_table AS table_name,
    column_profiles.column_name AS column_name,
    column_profiles.data_type AS data_type,
    column_profiles.has_masking_policy AS has_masking_policy,
    column_profiles.pii_tag AS pii_tag,
    column_profiles.profiled_at AS profiled_at
  )
  METRICS (
    write_log.batch_count AS COUNT(batch_id),
    write_log.total_rows_written AS SUM(rows_written),
    contracts.contract_count AS COUNT(contract_id),
    column_profiles.unmasked_phi_columns AS COUNT_IF(phi_pattern_rate > 0.5 AND NOT has_masking_policy) COMMENT = 'Columns that look like patient IDs but have no masking policy'
  )
  COMMENT = 'Governance metadata: batch provenance, contract status and column profiles. Holds no raw PHI.';

GRANT SELECT ON SEMANTIC VIEW HACKATHON_DB.GOV.GOVERNANCE_SV TO ROLE GOV_DATA_OWNER;
GRANT SELECT ON TABLE HACKATHON_DB.GOV.WRITE_LOG TO ROLE GOV_DATA_OWNER;
GRANT SELECT ON TABLE HACKATHON_DB.GOV.CONTRACTS TO ROLE GOV_DATA_OWNER;
GRANT SELECT ON TABLE HACKATHON_DB.GOV.COLUMN_PROFILES TO ROLE GOV_DATA_OWNER;

-- Check (as GOV_DATA_OWNER): Analyst on "Which LAB_RESULTS batches were written by an AI service account?"
-- generated the query below; expect LAB-B010 / SVC_GENAI_IMPUTER
USE SECONDARY ROLES NONE;
USE ROLE GOV_DATA_OWNER;
SELECT * FROM SEMANTIC_VIEW(
  HACKATHON_DB.GOV.GOVERNANCE_SV
  FACTS write_log.batch_id, write_log.table_name, write_log.written_by, write_log.written_at, write_log.rows_written
  WHERE write_log.source_type = 'ai' AND write_log.table_name LIKE '%LAB_RESULTS%'
);
USE ROLE GOV_ADMIN;
