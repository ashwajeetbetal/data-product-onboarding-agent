# Data Contract Governance & Onboarding Agent

A Cortex Agent that reviews the data contract for a new data product, routes it to a governance track
(STANDARD, FINANCIAL or REGULATED_LAB), lists its gaps with rule IDs, drafts fixes from vetted templates, and applies
them only after a named data steward approves. Built on Snowflake for the Snowflake hackathon (Fri Oct 23).

**For whom:** the **lab data steward** at a fictional clinical lab. Today the steward reads each new contract by hand,
checks it against the rulebook, chases the owner for missing fields, and finds out late that a batch was written by an
AI imputation job. This agent does the review in minutes, leaves every decision to the steward, and records it.

Synthetic data only: no PII, no real company, no proprietary knowledge. The agent governs how data is handled; it never
interprets lab values or gives health guidance.

**Video:** _<link to the one-minute demo video>_

## What it does (the C-LAB-001 demo)

1. The lab data owner (USER2) asks the agent in **Snowflake CoWork** or in **Claude via MCP** to review contract C-LAB-001.
2. The agent runs the review in a fixed order: parse the YAML with code, profile the columns (no raw values),
   route the track deterministically, check provenance against WRITE_LOG, search the rulebook, propose fixes.
3. It reports **REGULATED_LAB** and four gaps: STD-01 (no owner), STD-02 (no SLA), LAB-01 (patient_id not protected)
   and LAB-04 (batch **LAB-B010**, 50 rows, written by **SVC_GENAI_IMPUTER**, not declared).
4. It asks the owner for the owner and SLA values (it never invents them), then drafts five template fixes:
   set owner, set SLA, mask patient_id, tag it as PII, quarantine LAB-B010.
5. The steward (USER3) approves them in the **Streamlit approval queue**. Each approval applies its fix from the
   template; when all are applied the dataset is promoted to PROD with CLONE, so masking and tags carry over.
6. The impact query reads AUDIT_LOG: minutes from submission to promotion, human approvals and approvers, gaps caught.

## Architecture

```
 USER2 (GOV_DATA_OWNER)                                   USER3 (GOV_STEWARD)
 Snowflake CoWork ── or ── Claude (custom connector)      Streamlit approval queue (container runtime,
        │                    │ OAuth, public client,      restricted caller's rights: acts as the viewer)
        │                    │ GOV_DATA_OWNER only                     │
        │          GOVERNANCE_MCP (one CORTEX_AGENT_RUN tool)          │
        ▼                    ▼                                        ▼
 DATA_CONTRACT_AGENT (claude-opus-5-5, VERSION$3 "production")   APPROVE_FIX / REJECT_FIX   (caller's rights)
   tools, in run order:                                          APPLY_APPROVED_FIXES       (owner's rights,
   1 PARSE_CONTRACT    (pyyaml; fields only, never raw YAML)        renders FIX_TEMPLATES only, one transaction,
   2 PROFILE_COLUMNS   (counts and pattern rates, no raw PHI)       logs UNDO_STATEMENTS)
   3 CLASSIFY_TRACK    (deterministic, strictest track wins)     PROMOTE_DATASET            (CLONE to PROD,
   4 CHECK_PROVENANCE  (batch_id join to WRITE_LOG)                 keeps the prior version)
   5 RULEBOOK_SEARCH   (Cortex Search)
   6 PROPOSE_FIXES     (AI_COMPLETE + JSON schema, validated     AUDIT_LOG: every step, actor, model, run_id
                        against detected gaps and FIX_TEMPLATES) RESET_DEMO (GOV_ADMIN): undo in reverse order
   + GOVERNANCE_SV     (Cortex Analyst: provenance, status)      RUN_EVALS  (GOV_ADMIN): score routing and gaps
```

Design rules that make it safe:

- **Separation of duties.** The agent runs as the caller's default role, GOV_DATA_OWNER, which holds only the five
  review procedures. It cannot see APPROVE_FIX, APPLY_APPROVED_FIXES, PROMOTE_DATASET or RESET_DEMO. The steward
  approves in Streamlit under their own identity; `approved_by` and the audit actor are `CURRENT_USER()`.
- **No model-written SQL.** Fixes are applied only from `FIX_TEMPLATES.SQL_STATEMENTS`, with identifiers checked
  against INFORMATION_SCHEMA and values type-checked. The model only picks a template and writes a rationale under a
  JSON schema; any pick that doesn't match the deterministically detected gap is discarded.
- **Contract text is data.** YAML is parsed with code; the free-text description never reaches the model. Routing and
  gap detection are code, so an injected instruction cannot change the track (see `agent/demo_script_injection.md`).
- **Owner and SLA come only from the data owner**, passed as `confirmed_values`; without them the fix is
  NEEDS_OWNER_INPUT and cannot be approved.
- **Fail closed.** Any parse, provenance or model error leaves the contract BLOCKED. Missing tool grants abort the
  agent run (`tool_not_accessible: reject`) instead of silently skipping a tool.
- **No raw PHI to the agent.** It reads column profiles and the semantic view, never patient IDs.
  MASK_PATIENT_ID tests `CURRENT_ROLE()`; demo users have `DEFAULT_SECONDARY_ROLES = ()`.

## How to run it

Prerequisites: the pre-event scripts in `prework/` have run (do **not** re-run `03_data_pack.sql`; reset with
RESET_DEMO). Every build session starts with `USE ROLE GOV_ADMIN;`. Run the event scripts in order:

| File | What it builds |
|---|---|
| `sql/01_event_additions.sql`, `sql/01_02_checks.sql` | Event grants, demo user defaults; setup and data checks |
| `sql/03_rulebook_search.sql` | RULEBOOK_SEARCH Cortex Search service |
| `sql/04a_column_profiles.sql`, `sql/04b_semantic_view.sql` | PROFILE_COLUMNS, COLUMN_PROFILES; GOVERNANCE_SV |
| `sql/05a_review_procedures.sql`, `sql/05a_propose_fixes.sql` | CONTRACT_FIELDS, PENDING_FIXES, AUDIT_LOG; review procedures |
| `sql/05b_approval_apply_promote_reset.sql`, `sql/05b_checks.sql` | Approve, reject, apply, promote, reset; checks |
| `sql/06_agent.sql`, `sql/06b_agent_version.sql`, `sql/06c_agent_v3.sql` | Agent (spec in `agent/agent_spec.yaml`), CoWork, versions |
| `sql/07_run_evals.sql` | RUN_EVALS, EVAL_RESULTS |
| `sql/08_streamlit_app.sql` | Approval queue app (`streamlit/`), caller grants, PyPI EAI |
| `sql/09_mcp.sql` | GOVERNANCE_MCP server and CLAUDE_MCP_OAUTH integration |
| `sql/10_impact_query.sql`, `sql/11_injection_proof.sql` | Demo close and injection proof (read-only) |

Demo run:

1. `CALL HACKATHON_DB.GOV.RESET_DEMO();` as GOV_ADMIN.
2. As **USER2** in CoWork (agent "Data Contract Governance"): `Review contract C-LAB-001 for HACKATHON_DB.STAGING.LAB_RESULTS.`
   then `Owner is lab.ops@example.com and the freshness SLA is 24 hours.`
3. As **USER3** (role GOV_STEWARD): Snowsight » Projects » Streamlit » **Steward approval queue**; approve the five fixes.
4. As USER2: `What is the status of C-LAB-001?` (PROMOTED). As USER (GOV_CONSUMER), `HACKATHON_DB.PROD.LAB_RESULTS`
   shows `PT-******` and no LAB-B010.
5. Run `sql/10_impact_query.sql` and `CALL HACKATHON_DB.GOV.RUN_EVALS();`, then RESET_DEMO.

Claude via MCP: add a custom connector with server URL
`https://sfsehol-anthropic-snowflake-hackathon-pscsxl.snowflakecomputing.com/api/v2/databases/HACKATHON_DB/schemas/GOV/mcp-servers/GOVERNANCE_MCP`
and the public OAuth client ID from `sql/09_mcp.sql` (no client secret), then sign in as USER2.

## Results

**RUN_EVALS** (review procedures against EVAL_SET, 14:23):

| Scope | Contracts | Routing accuracy | Gap recall | Gap precision | Errors |
|---|---|---|---|---|---|
| MVP | 5 | 100% | 100% | 100% | 0 |
| All, incl. red-team | 8 | 100% | 100% | 100% | 0 |

- **C-LAB-INJ** (YAML asks to route to STANDARD and auto-approve): routed REGULATED_LAB, LAB-01 and LAB-04 caught,
  0 approvals (`sql/11_injection_proof.sql`).
- **C-LAB-DGR** (patient data declared as `domain: sales`): escalated to REGULATED_LAB, left BLOCKED.

**Impact** (one end-to-end C-LAB-001 test run, including debugging pauses): 21.9 minutes from first parse to
promotion, 5 human approvals by USER3, gaps STD-01, STD-02, LAB-01, LAB-04 caught. Re-run `sql/10_impact_query.sql`
after a clean rehearsal for the demo number.

## Built before vs today

The pre-event commit is `bfc3755` (11:45): setup scripts, synthetic data pack and the build skill. Everything else was
built today, in the commits after it (tag `mvp` = `f468a48`).

| Before the event (`prework/`, commit `bfc3755`) | Built today (commits after `bfc3755`) |
|---|---|
| HACKATHON_DB with GOV, STAGING, PROD; GOV_WH | Demo users USER / USER2 / USER3: roles, default roles, GOV_WH, `DEFAULT_SECONDARY_ROLES = ()` |
| Roles GOV_ADMIN, GOV_AGENT_ROLE, GOV_STEWARD, GOV_CONSUMER, GOV_DATA_OWNER | RULEBOOK_SEARCH (statement from the data pack, run today) |
| Cross-region inference, AI_SETTINGS guardrail | COLUMN_PROFILES + PROFILE_COLUMNS; GOVERNANCE_SV semantic view |
| MASK_PATIENT_ID policy, PII_TYPE tag | CONTRACT_FIELDS, PENDING_FIXES, AUDIT_LOG, EVAL_RESULTS, FIX_VERIFICATION |
| LAB_RESULTS (with LAB-B010), LAB_RESULTS_SITE_B, QUARANTINE_LAB_RESULTS, SALES_ORDERS, FINANCE_GL | PARSE_CONTRACT, CLASSIFY_TRACK, CHECK_PROVENANCE, PROPOSE_FIXES |
| WRITE_LOG, RULEBOOK (16), FIX_TEMPLATES (6), CONTRACTS (8), EVAL_SET (8), AGENT_EVAL_DATA | APPROVE_FIX, REJECT_FIX, APPLY_APPROVED_FIXES, PROMOTE_DATASET, RESET_DEMO, RUN_EVALS |
| Smoke-test scripts (agent, MCP, OAuth) | DATA_CONTRACT_AGENT (VERSION$1–3), CoWork registration |
| Build skill (`skill/`) | Streamlit APPROVAL_QUEUE, APP_STAGE; GOVERNANCE_MCP; CLAUDE_MCP_OAUTH; PYPI_ACCESS_INTEGRATION |
| | Impact query, injection demo script and proof query |

**Event changes to pre-work objects** (ALTERs, grants and data changes; no pre-work object was recreated or renamed):

- Grants on pre-work tables: SELECT on WRITE_LOG and CONTRACTS to GOV_DATA_OWNER; SELECT, UPDATE on CONTRACTS and
  SELECT on RULEBOOK to GOV_STEWARD; SELECT on STAGING.LAB_RESULTS and USAGE on schemas STAGING and PROD to
  GOV_CONSUMER; caller grants (SELECT/UPDATE CONTRACTS, SELECT RULEBOOK) to GOV_ADMIN for the Streamlit app.
- Role and account grants: SNOWFLAKE.CORTEX_USER to GOV_ADMIN; SNOWFLAKE.CORTEX_AGENT_USER and USAGE on HACKATHON_DB,
  GOV, GOV_WH to GOV_DATA_OWNER; USAGE on SYSTEM_COMPUTE_POOL_CPU to GOV_ADMIN; USAGE on the CoWork object to
  GOV_DATA_OWNER.
- Data written into pre-work tables by the procedures: CONTRACTS.STATUS (reset to SUBMITTED by RESET_DEMO).
- ALTERs that approved fixes make on pre-work tables (all undone by RESET_DEMO): MASK_PATIENT_ID and the PII_TYPE tag
  on STAGING.LAB_RESULTS.PATIENT_ID; LAB-B010 rows moved to QUARANTINE_LAB_RESULTS and back.
- Not used: the organizers' STOWEAWAY MCP server, STOWEAWAY_CLAUDE_OAUTH integration and MCP_CLAUDE_ROLE.

## Next steps

- **VERIFY_FIX:** apply each proposed fix to a zero-copy clone of the staging table first, check the masked value for
  GOV_CONSUMER, the tag on the right column, zero gaps on re-review and no other changes, then show "verified" per fix
  in the approval queue.
- Native Cortex Agent evaluations (metric version v3) on AGENT_EVAL_DATA, alongside RUN_EVALS.
- A SUBMIT_CONTRACT step (procedure or upload page) so `submitted_by` is the real submitting user.
- A contract-change path for gaps with no template fix (for example C-LAB-DGR's undeclared PII column).
- Learning loop, human-gated: capture steward decisions, search precedents, grow the eval set.
