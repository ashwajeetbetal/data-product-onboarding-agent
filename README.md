# data-product-onboarding-agent

Data Contract Governance & Onboarding Agent (Snowflake hackathon, synthetic data only).

## Pre-event objects
Created by `prework/01_setup.sql` and `prework/03_data_pack.sql`: HACKATHON_DB (GOV, STAGING, PROD), GOV_WH, roles GOV_ADMIN / GOV_AGENT_ROLE / GOV_STEWARD / GOV_CONSUMER / GOV_DATA_OWNER, MASK_PATIENT_ID, PII_TYPE tag, LAB_RESULTS, LAB_RESULTS_SITE_B, QUARANTINE_LAB_RESULTS, SALES_ORDERS, FINANCE_GL, WRITE_LOG, RULEBOOK, FIX_TEMPLATES, CONTRACTS, EVAL_SET, AGENT_EVAL_DATA.

## Event work
- Phase 1 grants and user defaults (`sql/01_event_additions.sql`): CORTEX_USER to GOV_ADMIN; CORTEX_AGENT_USER and USAGE on HACKATHON_DB, GOV and GOV_WH to GOV_DATA_OWNER; demo users USER (GOV_CONSUMER), USER2 (GOV_DATA_OWNER), USER3 (GOV_STEWARD), each also granted GOV_ADMIN, with DEFAULT_WAREHOUSE = GOV_WH and DEFAULT_SECONDARY_ROLES = ().
- Phase 1–2 checks: `sql/01_02_checks.sql`.
- Phase 8: PYPI_ACCESS_INTEGRATION (PyPI-only EAI on snowflake.external_access.pypi_rule) for the Streamlit container runtime; caller grants to GOV_ADMIN; USAGE on SYSTEM_COMPUTE_POOL_CPU to GOV_ADMIN.
