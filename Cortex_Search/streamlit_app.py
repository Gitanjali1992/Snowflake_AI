import streamlit as st
import pandas as pd
import json
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Policy Handbook", layout="wide")
session = get_active_session()

DB_SCHEMA = "policy_poc_db.policy_poc"

# ------------------------------------------------------------------
# Company selector (worth having even with two docs, since the two
# entities' thresholds could diverge as more policies get added)
# ------------------------------------------------------------------
docs_df = session.sql(f"SELECT doc_id, entity_name, title FROM {DB_SCHEMA}.policy_documents").to_pandas()
entity = st.sidebar.selectbox("Entity", docs_df["ENTITY_NAME"].unique())
doc_ids = docs_df[docs_df["ENTITY_NAME"] == entity]["DOC_ID"].tolist()

page = st.sidebar.radio(
    "Browse",
    ["Thresholds", "Definitions", "Roles", "Obligations", "Ask"],
)

doc_filter = "(" + ", ".join(f"'{d}'" for d in doc_ids) + ")"

# ------------------------------------------------------------------
if page == "Thresholds":
    st.subheader(f"{entity} — quick-reference thresholds")
    df = session.sql(
        f"SELECT description, value_text, source_section FROM {DB_SCHEMA}.policy_thresholds "
        f"WHERE doc_id IN {doc_filter}"
    ).to_pandas()
    if df.empty:
        st.info("No thresholds extracted for this entity yet.")
    else:
        cols = st.columns(min(len(df), 4))
        for i, row in df.iterrows():
            with cols[i % len(cols)]:
                st.metric(row["DESCRIPTION"], row["VALUE_TEXT"])
                st.caption(row["SOURCE_SECTION"])

# ------------------------------------------------------------------
elif page == "Definitions":
    st.subheader(f"{entity} — defined terms")
    df = session.sql(
        f"SELECT term, definition FROM {DB_SCHEMA}.policy_definitions WHERE doc_id IN {doc_filter} ORDER BY term"
    ).to_pandas()
    search = st.text_input("Filter terms")
    if search:
        df = df[df["TERM"].str.contains(search, case=False, na=False)]
    st.dataframe(df, use_container_width=True, hide_index=True)

# ------------------------------------------------------------------
elif page == "Roles":
    st.subheader(f"{entity} — roles and responsibilities")
    df = session.sql(
        f"SELECT role_name, responsibilities FROM {DB_SCHEMA}.policy_roles WHERE doc_id IN {doc_filter}"
    ).to_pandas()
    for _, row in df.iterrows():
        with st.expander(row["ROLE_NAME"]):
            st.write(row["RESPONSIBILITIES"])

# ------------------------------------------------------------------
elif page == "Obligations":
    st.subheader(f"{entity} — obligations")
    df = session.sql(
        f"SELECT topic, obligation_text, obligation_type FROM {DB_SCHEMA}.policy_obligations "
        f"WHERE doc_id IN {doc_filter}"
    ).to_pandas()
    topics = ["All"] + sorted(df["TOPIC"].dropna().unique().tolist())
    topic_choice = st.selectbox("Topic", topics)
    if topic_choice != "All":
        df = df[df["TOPIC"] == topic_choice]
    for otype, group in df.groupby("OBLIGATION_TYPE"):
        st.markdown(f"**{otype.title()}**")
        for _, row in group.iterrows():
            st.markdown(f"- {row['OBLIGATION_TEXT']}")

# ------------------------------------------------------------------
elif page == "Ask":
    st.subheader(f"{entity} — ask the policy")
    query = st.text_input("Question")
    if query:
        result = session.sql(
            "SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(?, ?)",
            params=[
                f"{DB_SCHEMA}.policy_search_svc",
                json.dumps({
                    "query": query,
                    "columns": ["chunk_text", "doc_id", "chunk_topic"],
                    "filter": {"@and": [{"@eq": {"doc_id": doc_ids[0]}}]} if len(doc_ids) == 1 else None,
                    "limit": 5,
                }),
            ],
        ).collect()
        payload = json.loads(result[0][0])
        # Cortex Search returns a reranker_score on every result whether or
        # not it's requested in "columns" — a large gap between a genuinely
        # relevant result and a merely topically-adjacent one is normal
        # (seen in testing: ~1.0 for a real answer vs. -5 to -8 for noise).
        # Filtering below zero keeps the tab from showing weak matches with
        # the same visual weight as a strong one.
        relevant = [
            r for r in payload.get("results", [])
            if r.get("@scores", {}).get("reranker_score", 0) > 0
        ]
        if not relevant:
            st.info("No strongly relevant passage found for that question.")
        for r in relevant:
            st.markdown(f"**[{r.get('chunk_topic', 'uncategorised')}]**")
            st.write(r["chunk_text"])
            st.caption(f"Relevance score: {r['@scores']['reranker_score']:.2f}")
            st.divider()
