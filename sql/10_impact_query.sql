-- Demo close: impact for the data steward, from AUDIT_LOG sorted by ts (audit_id is not time-ordered).
-- Latest C-LAB-001 run = rows after the last RESET / EVAL_RUN that precedes the latest PROMOTE_DATASET.
USE ROLE GOV_ADMIN;

WITH promote AS (
  SELECT MAX(ts) AS promoted_at FROM HACKATHON_DB.GOV.AUDIT_LOG
  WHERE contract_id = 'C-LAB-001' AND action = 'PROMOTE_DATASET'
),
run_start AS (
  -- the run begins after the last reset or eval run that precedes the promotion
  SELECT p.promoted_at,
         COALESCE(MAX(a.ts), '1970-01-01'::TIMESTAMP_NTZ) AS after_ts
  FROM promote p
  LEFT JOIN HACKATHON_DB.GOV.AUDIT_LOG a ON a.action IN ('RESET', 'EVAL_RUN') AND a.ts < p.promoted_at
  GROUP BY p.promoted_at
),
run AS (
  SELECT a.* FROM HACKATHON_DB.GOV.AUDIT_LOG a, run_start r
  WHERE a.contract_id = 'C-LAB-001' AND a.ts > r.after_ts AND a.ts <= r.promoted_at
)
SELECT
  MIN(IFF(action = 'PARSE_CONTRACT', ts, NULL)) AS first_parse_at,
  MAX(IFF(action = 'PROMOTE_DATASET', ts, NULL)) AS promoted_at,
  ROUND(DATEDIFF('second', first_parse_at, promoted_at) / 60, 1) AS minutes_to_promotion,
  COUNT_IF(action = 'APPROVE_FIX') AS human_approvals,
  ARRAY_TO_STRING(ARRAY_AGG(DISTINCT IFF(action = 'APPROVE_FIX', actor, NULL)), ', ') AS approvers,
  ARRAY_TO_STRING(MAX_BY(IFF(action = 'PROPOSE_FIXES', details:gaps, NULL), IFF(action = 'PROPOSE_FIXES', ts, NULL))::ARRAY, ', ') AS gaps_caught
FROM run;
-- Tested 14:25 on the USER3 app run: 13:40:29 -> 14:02:23, 21.9 minutes, 5 approvals by USER3,
-- gaps STD-01, STD-02, LAB-01, LAB-04.

-- Beside it: the latest RUN_EVALS score
SELECT ts, details:scope::STRING AS scope, details:contracts::INT AS contracts,
       details:routing_accuracy::FLOAT AS routing_accuracy, details:gap_recall::FLOAT AS gap_recall,
       details:gap_precision::FLOAT AS gap_precision, details:errors::INT AS errors
FROM HACKATHON_DB.GOV.AUDIT_LOG WHERE action = 'EVAL_RUN' ORDER BY ts DESC LIMIT 1;
-- Rehearsal 15:10: 14:51:56 -> 15:08:54, 17.0 minutes, 5 approvals by USER3, gaps STD-01, STD-02, LAB-01, LAB-04.
-- Clean dry run 15:41: 15:35:32 -> 15:38:57, 3.4 minutes, 5 approvals by USER3, gaps STD-01, STD-02, LAB-01, LAB-04.
