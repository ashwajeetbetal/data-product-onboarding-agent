-- Punch item 1: Claude via a Snowflake-managed MCP server. Our own objects only: the organizers'
-- STOWEAWAY.ANALYTICS.CLAUDE_MCP_ACCESS / STOWEAWAY_CLAUDE_OAUTH / MCP_CLAUDE_ROLE are not used.
-- Exposes only the agent (never SYSTEM_EXECUTE_SQL); only GOV_DATA_OWNER can connect.

-- OAuth: public client (PKCE, no secret). Redirect URI per Snowflake's MCP docs for claude.ai.
USE ROLE ACCOUNTADMIN;
CREATE SECURITY INTEGRATION IF NOT EXISTS CLAUDE_MCP_OAUTH
  TYPE = OAUTH
  OAUTH_CLIENT = CUSTOM
  ENABLED = TRUE
  OAUTH_CLIENT_TYPE = 'PUBLIC'
  OAUTH_REDIRECT_URI = 'https://claude.ai/api/mcp/auth_callback'
  OAUTH_USE_SECONDARY_ROLES = NONE
  ALLOWED_ROLES_LIST = ('GOV_DATA_OWNER')
  COMMENT = 'Claude custom connector for HACKATHON_DB.GOV.GOVERNANCE_MCP (data owner only)';
-- Client ID for the Claude connector (public client: never commit any client secret)
SELECT PARSE_JSON(SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('CLAUDE_MCP_OAUTH')):OAUTH_CLIENT_ID::STRING AS oauth_client_id;

USE ROLE GOV_ADMIN;
CREATE OR REPLACE MCP SERVER HACKATHON_DB.GOV.GOVERNANCE_MCP
  FROM SPECIFICATION $$
  tools:
    - title: "Data Contract Governance agent"
      name: "data_contract_governance"
      type: "CORTEX_AGENT_RUN"
      identifier: "HACKATHON_DB.GOV.DATA_CONTRACT_AGENT"
      description: "Reviews a data contract for a new data product: routes it to a governance track, lists gaps with rule IDs and drafts template fixes for steward approval. Also answers contract status questions. Never approves fixes."
      annotations:
        openWorldHint: false
  $$;
-- GOV_DATA_OWNER already has USAGE on the agent, SNOWFLAKE.CORTEX_AGENT_USER and every tool grant (Phase 5a/6)
GRANT USAGE ON MCP SERVER HACKATHON_DB.GOV.GOVERNANCE_MCP TO ROLE GOV_DATA_OWNER;
DESCRIBE MCP SERVER HACKATHON_DB.GOV.GOVERNANCE_MCP;

-- Server URL (hyphens, not underscores, in the account host):
-- https://sfsehol-anthropic-snowflake-hackathon-pscsxl.snowflakecomputing.com/api/v2/databases/HACKATHON_DB/schemas/GOV/mcp-servers/GOVERNANCE_MCP
