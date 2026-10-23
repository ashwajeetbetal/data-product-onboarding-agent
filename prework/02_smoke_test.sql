-- 02_smoke_test.sql  (about 15 minutes)
-- Proves three things before the hackathon: an agent runs, it can be exposed over MCP,
-- and Claude can connect to it with OAuth.
-- Run after 01_setup.sql, as ACCOUNTADMIN (the OAuth integration needs CREATE INTEGRATION).
-- Prepared for user USER2.

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE GOV_WH;

-- 0. The organizers created MCP_CLAUDE_ROLE, so look at what already exists first
SHOW INTEGRATIONS;
SHOW MCP SERVERS IN ACCOUNT;

-- 1. A tiny agent with no tools
CREATE OR REPLACE AGENT HACKATHON_DB.GOV.SMOKE_AGENT
  COMMENT = 'Smoke test agent'
  PROFILE = '{"display_name": "Smoke test agent"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto

  instructions:
    response: "Answer in one short sentence."
  $$;

-- 2. Expose only that agent through a Snowflake-managed MCP server
CREATE OR REPLACE MCP SERVER HACKATHON_DB.GOV.SMOKE_MCP
  FROM SPECIFICATION $$
  tools:
    - title: "Smoke test agent"
      name: "smoke_agent"
      type: "CORTEX_AGENT_RUN"
      identifier: "HACKATHON_DB.GOV.SMOKE_AGENT"
      description: "Test agent for checking the Claude connection."
  $$;

GRANT USAGE ON AGENT HACKATHON_DB.GOV.SMOKE_AGENT TO ROLE GOV_DATA_OWNER;
GRANT USAGE ON MCP SERVER HACKATHON_DB.GOV.SMOKE_MCP TO ROLE GOV_DATA_OWNER;

-- 3. OAuth for Claude (public client, data owner role only)
CREATE OR REPLACE SECURITY INTEGRATION CLAUDE_MCP_OAUTH
  TYPE = OAUTH
  OAUTH_CLIENT = CUSTOM
  ENABLED = TRUE
  OAUTH_CLIENT_TYPE = 'PUBLIC'
  OAUTH_REDIRECT_URI = 'https://claude.ai/api/mcp/auth_callback'
  OAUTH_USE_SECONDARY_ROLES = NONE
  ALLOWED_ROLES_LIST = ('GOV_DATA_OWNER');

-- Copy OAUTH_CLIENT_ID and OAUTH_CLIENT_SECRET from this result
SELECT SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('CLAUDE_MCP_OAUTH');

-- 4. Claude sessions use your default role, so make it the data owner role for this test.
--    (Switch roles in Snowsight as needed; set it back later if you like.)
ALTER USER "USER2" SET DEFAULT_ROLE = GOV_DATA_OWNER;

-- 5. In Claude: Settings > Connectors > Add custom connector
--    Server URL:
--    https://<your account URL>/api/v2/databases/HACKATHON_DB/schemas/GOV/mcp-servers/SMOKE_MCP
--    (copy the account URL from Snowsight: avatar > Connect a tool to Snowflake)
--    Paste the client ID and secret, approve the Snowflake consent screen,
--    then ask Claude: "Use the smoke test agent to tell me what it can do."
