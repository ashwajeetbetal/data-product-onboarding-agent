-- Phase 3: rulebook search service (event work; statement from 03_data_pack.sql section 8)
USE ROLE GOV_ADMIN;

CREATE OR REPLACE CORTEX SEARCH SERVICE HACKATHON_DB.GOV.RULEBOOK_SEARCH
  ON rule_text
  ATTRIBUTES track, rule_id
  WAREHOUSE = GOV_WH
  TARGET_LAG = '1 day'
  AS (SELECT rule_id, track, title, rule_text, version, owner FROM HACKATHON_DB.GOV.RULEBOOK);

GRANT USAGE ON CORTEX SEARCH SERVICE HACKATHON_DB.GOV.RULEBOOK_SEARCH TO ROLE GOV_DATA_OWNER;

-- Check: as GOV_DATA_OWNER, "patient identifiers" returns LAB-01 near the top
USE SECONDARY ROLES NONE;
USE ROLE GOV_DATA_OWNER;
SELECT PARSE_JSON(
  SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'HACKATHON_DB.GOV.RULEBOOK_SEARCH',
    '{"query": "patient identifiers", "columns": ["rule_id", "title", "track"], "limit": 3}'
  )
):results AS top_rules;
USE ROLE GOV_ADMIN;
