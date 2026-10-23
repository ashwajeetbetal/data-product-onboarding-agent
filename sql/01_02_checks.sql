-- Phase 1 and Phase 2 checks (read-only; pre-event objects are verified, never recreated).
USE ROLE GOV_ADMIN;

-- Phase 1 -------------------------------------------------------------------
-- Account settings (need ACCOUNTADMIN to view)
USE ROLE ACCOUNTADMIN;
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;   -- expect ANY_REGION
SHOW PARAMETERS LIKE 'AI_SETTINGS' IN ACCOUNT;                   -- expect advanced_prompt_injection enabled
SHOW USERS LIKE 'USER%';  -- USER/USER2/USER3: default role, GOV_WH, secondary roles []
USE ROLE GOV_ADMIN;

SELECT CURRENT_ROLE() AS r, AI_COMPLETE('claude-sonnet-5', 'Reply with one word: ready') AS claude_check;
DESCRIBE MASKING POLICY HACKATHON_DB.GOV.MASK_PATIENT_ID;        -- expect CURRENT_ROLE()
SELECT schema_name, schema_owner FROM HACKATHON_DB.INFORMATION_SCHEMA.SCHEMATA
WHERE schema_name IN ('GOV', 'STAGING', 'PROD') ORDER BY 1;      -- expect GOV_ADMIN

-- Phase 2 -------------------------------------------------------------------
SELECT 'LAB_RESULTS' AS t, COUNT(*) AS n FROM HACKATHON_DB.STAGING.LAB_RESULTS
UNION ALL SELECT 'LAB_RESULTS_SITE_B', COUNT(*) FROM HACKATHON_DB.STAGING.LAB_RESULTS_SITE_B
UNION ALL SELECT 'SALES_ORDERS', COUNT(*) FROM HACKATHON_DB.STAGING.SALES_ORDERS
UNION ALL SELECT 'FINANCE_GL', COUNT(*) FROM HACKATHON_DB.STAGING.FINANCE_GL
UNION ALL SELECT 'WRITE_LOG', COUNT(*) FROM HACKATHON_DB.GOV.WRITE_LOG
UNION ALL SELECT 'RULEBOOK', COUNT(*) FROM HACKATHON_DB.GOV.RULEBOOK
UNION ALL SELECT 'FIX_TEMPLATES', COUNT(*) FROM HACKATHON_DB.GOV.FIX_TEMPLATES
UNION ALL SELECT 'CONTRACTS', COUNT(*) FROM HACKATHON_DB.GOV.CONTRACTS
UNION ALL SELECT 'EVAL_SET', COUNT(*) FROM HACKATHON_DB.GOV.EVAL_SET
UNION ALL SELECT 'QUARANTINE_LAB_RESULTS', COUNT(*) FROM HACKATHON_DB.STAGING.QUARANTINE_LAB_RESULTS;
-- Expect 500, 100, 500, 500, 17, 16, 6, 8, 8, 0

SELECT table_schema || '.' || table_name AS tbl,
       LISTAGG(column_name || ':' || data_type, ', ') WITHIN GROUP (ORDER BY ordinal_position) AS cols
FROM HACKATHON_DB.INFORMATION_SCHEMA.COLUMNS WHERE table_schema IN ('GOV', 'STAGING') GROUP BY 1 ORDER BY 1;

-- Quarantine has the same columns as LAB_RESULTS (expect 0)
SELECT COUNT(*) AS mismatches FROM (
  (SELECT column_name, data_type, ordinal_position FROM HACKATHON_DB.INFORMATION_SCHEMA.COLUMNS
    WHERE table_schema = 'STAGING' AND table_name = 'LAB_RESULTS'
   MINUS SELECT column_name, data_type, ordinal_position FROM HACKATHON_DB.INFORMATION_SCHEMA.COLUMNS
    WHERE table_schema = 'STAGING' AND table_name = 'QUARANTINE_LAB_RESULTS')
  UNION ALL
  (SELECT column_name, data_type, ordinal_position FROM HACKATHON_DB.INFORMATION_SCHEMA.COLUMNS
    WHERE table_schema = 'STAGING' AND table_name = 'QUARANTINE_LAB_RESULTS'
   MINUS SELECT column_name, data_type, ordinal_position FROM HACKATHON_DB.INFORMATION_SCHEMA.COLUMNS
    WHERE table_schema = 'STAGING' AND table_name = 'LAB_RESULTS'));

SELECT * FROM HACKATHON_DB.GOV.WRITE_LOG WHERE source_type = 'ai';  -- expect LAB-B010 / SVC_GENAI_IMPUTER

-- Lab gaps: no owner, no SLA, patient_id pii: false, declared_source [instrument] only
SELECT contract_id, status, is_test, yaml FROM HACKATHON_DB.GOV.CONTRACTS WHERE contract_id = 'C-LAB-001';

-- Event rule: fake data only (expect all example.com, no other addresses)
SELECT COUNT(*) AS total, COUNT_IF(customer_email ILIKE '%@example.%') AS example_emails
FROM HACKATHON_DB.STAGING.SALES_ORDERS;
SELECT 'CONTRACTS' AS src, f.value::STRING AS addr
FROM HACKATHON_DB.GOV.CONTRACTS c, LATERAL FLATTEN(REGEXP_SUBSTR_ALL(c.yaml, '[A-Za-z0-9._-]+@[A-Za-z0-9.-]+')) f
WHERE f.value::STRING NOT ILIKE '%@example.%'
UNION ALL SELECT 'RULEBOOK', owner FROM HACKATHON_DB.GOV.RULEBOOK
WHERE owner ILIKE '%@%' AND owner NOT ILIKE '%@example.%';

-- Masking: consumer sees PT-******, steward sees real IDs
USE SECONDARY ROLES NONE;
USE ROLE GOV_CONSUMER;
SELECT CURRENT_ROLE() AS role, patient_id FROM HACKATHON_DB.STAGING.LAB_RESULTS_SITE_B LIMIT 2;
USE ROLE GOV_STEWARD;
SELECT CURRENT_ROLE() AS role, patient_id = 'PT-******' AS masked FROM HACKATHON_DB.STAGING.LAB_RESULTS_SITE_B LIMIT 2;
USE ROLE GOV_ADMIN;
