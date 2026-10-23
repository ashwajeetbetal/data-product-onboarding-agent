-- Phase 6c: VERSION$3 - status questions answered from CONTRACTS.STATUS; the approval line only when fixes are pending.
-- Full spec: agent/agent_spec.yaml (MODIFY LIVE VERSION SET SPECIFICATION replaces the whole spec).
USE ROLE GOV_ADMIN;
ALTER AGENT HACKATHON_DB.GOV.DATA_CONTRACT_AGENT ADD LIVE VERSION FROM LAST COMMENT = 'V3: status answers and conditional approval line';
-- ALTER AGENT HACKATHON_DB.GOV.DATA_CONTRACT_AGENT MODIFY LIVE VERSION SET SPECIFICATION = $$ <agent/agent_spec.yaml> $$;

-- Check on LIVE as GOV_DATA_OWNER (after RESET_DEMO): expect governance_analyst only, status SUBMITTED, no "waiting" line
USE SECONDARY ROLES NONE;
USE ROLE GOV_DATA_OWNER;
WITH r AS (SELECT TRY_PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN('HACKATHON_DB.GOV.DATA_CONTRACT_AGENT!LIVE',
  $${"messages": [{"role": "user", "content": [{"type": "text", "text": "What is the status of C-LAB-001?"}]}]}$$, FALSE)) AS j)
SELECT
  (SELECT LISTAGG(c.value:tool_use:name::STRING, ' > ') FROM r, LATERAL FLATTEN(j:content) c WHERE c.value:type = 'tool_use') AS tool_order,
  (SELECT LISTAGG(c.value:text::STRING, '') FROM r, LATERAL FLATTEN(j:content) c WHERE c.value:type = 'text') AS answer;

USE ROLE GOV_ADMIN;
ALTER AGENT HACKATHON_DB.GOV.DATA_CONTRACT_AGENT COMMIT COMMENT = 'V3: status answers from CONTRACTS.STATUS; approval line only when fixes are pending';
ALTER AGENT HACKATHON_DB.GOV.DATA_CONTRACT_AGENT MODIFY VERSION VERSION$3 SET ALIAS = production;
ALTER AGENT HACKATHON_DB.GOV.DATA_CONTRACT_AGENT SET DEFAULT_VERSION = 'VERSION$3';
SHOW VERSIONS IN AGENT HACKATHON_DB.GOV.DATA_CONTRACT_AGENT;
