"""Steward approval queue for the Data Contract Governance agent.

Runs with restricted caller's rights: every query and procedure call runs as the viewer
(their default role), so APPROVE_FIX records the steward who clicked, never the app owner.
"""
import json

import streamlit as st

# Caller's-rights token is only valid briefly after session start: create the connection first, at top level
conn = st.connection("snowflake-callers-rights")

st.set_page_config(page_title="Steward approval queue", layout="wide")


def query(sql, params=None):
    return conn.query(sql, params=params, ttl=0)


def call(proc, *args):
    """CALL a governance procedure with bound arguments and return its VARIANT result as a dict."""
    placeholders = ", ".join(["%s"] * len(args))
    cur = conn.cursor()
    try:
        cur.execute(f"CALL HACKATHON_DB.GOV.{proc}({placeholders})", args)
        raw = cur.fetchone()[0]
    finally:
        cur.close()
    return json.loads(raw) if isinstance(raw, str) else raw


me = query("SELECT CURRENT_USER() AS u, CURRENT_ROLE() AS r")
viewer, role = me["U"][0], me["R"][0]

st.title("Steward approval queue")
st.caption(f"Signed in as **{viewer}** with role **{role}**. Approvals are recorded under your name.")

if "flash" in st.session_state:
    kind, msg = st.session_state.pop("flash")
    (st.success if kind == "ok" else st.error)(msg)

# ---- Contract status -------------------------------------------------------------------------
st.subheader("Contracts")
contracts = query("""
    SELECT contract_id, table_name, status
    FROM HACKATHON_DB.GOV.CONTRACTS
    WHERE NOT is_test
    ORDER BY contract_id
""")
cols = st.columns(max(len(contracts), 1))
for col, (_, c) in zip(cols, contracts.iterrows()):
    col.metric(c["CONTRACT_ID"], c["STATUS"], help=c["TABLE_NAME"], border=True)

# ---- Approval queue --------------------------------------------------------------------------
st.subheader("Fixes waiting for approval")
fixes = query("""
    SELECT p.fix_id, p.contract_id, p.rule_id, r.title AS rule_title, r.rule_text, p.template_id,
           p.target_table, p.target_column, p.value, p.rationale
    FROM HACKATHON_DB.GOV.PENDING_FIXES p
    LEFT JOIN HACKATHON_DB.GOV.RULEBOOK r ON r.rule_id = p.rule_id
    WHERE p.status = 'PROPOSED'
    ORDER BY p.contract_id, p.rule_id, p.template_id
""")

if role != "GOV_STEWARD":
    st.warning("Only GOV_STEWARD can approve or reject. Set your default role to GOV_STEWARD to act on this queue.")

if fixes.empty:
    st.info("No fixes are waiting for approval.")


def approve(fix_id, contract_id):
    res = call("APPROVE_FIX", fix_id)
    if res.get("status") != "OK":
        st.session_state["flash"] = ("err", f"Approve failed for {fix_id}: {res.get('message')}")
        return
    approver = res.get("approved_by")
    applied = call("APPLY_APPROVED_FIXES", fix_id)
    if applied.get("status") != "OK":
        st.session_state["flash"] = ("err", f"{fix_id} approved by {approver}, but apply failed: {applied.get('message')}")
        return
    msg = f"{fix_id} approved by {approver} and applied."
    if applied.get("open_fixes_for_contract") == 0:
        promoted = call("PROMOTE_DATASET", contract_id)
        if promoted.get("status") == "OK":
            msg += f" All fixes applied: {contract_id} promoted to {promoted.get('promoted_to')}."
        else:
            msg += f" Promotion not done: {promoted.get('message')}"
    st.session_state["flash"] = ("ok", msg)


def reject(fix_id, reason):
    res = call("REJECT_FIX", fix_id, reason)
    if res.get("status") == "OK":
        st.session_state["flash"] = ("ok", f"{fix_id} rejected by {viewer}. Contract set to CHANGES_REQUESTED.")
    else:
        st.session_state["flash"] = ("err", f"Reject failed for {fix_id}: {res.get('message')}")


for _, f in fixes.iterrows():
    with st.container(border=True):
        left, right = st.columns([4, 1])
        with left:
            st.markdown(f"**{f['FIX_ID']}** · {f['CONTRACT_ID']} · `{f['TEMPLATE_ID']}`")
            st.markdown(f"**{f['RULE_ID']} – {f['RULE_TITLE'] or ''}**: {f['RULE_TEXT'] or ''}")
            target = f"{f['TARGET_TABLE']}.{f['TARGET_COLUMN']}"
            value = "" if f["VALUE"] is None else f" = `{f['VALUE']}`"
            st.markdown(f"Target: `{target}`{value}")
            st.caption(f"Evidence: {f['RATIONALE']}")
        with right:
            disabled = role != "GOV_STEWARD"
            if st.button("Approve", key=f"approve_{f['FIX_ID']}", type="primary", disabled=disabled, width="stretch"):
                with st.spinner(f"Approving and applying {f['FIX_ID']}..."):
                    approve(f["FIX_ID"], f["CONTRACT_ID"])
                st.rerun()
            with st.popover("Reject", disabled=disabled, width="stretch"):
                reason = st.text_input("Reason", key=f"reason_{f['FIX_ID']}")
                if st.button("Confirm reject", key=f"reject_{f['FIX_ID']}", disabled=not reason):
                    reject(f["FIX_ID"], reason)
                    st.rerun()

# ---- Audit log -------------------------------------------------------------------------------
st.subheader("Audit log")
audit = query("""
    SELECT ts, actor, action, contract_id, fix_id, model
    FROM HACKATHON_DB.GOV.AUDIT_LOG
    ORDER BY audit_id DESC
    LIMIT 50
""")
st.dataframe(audit, hide_index=True, width="stretch")
