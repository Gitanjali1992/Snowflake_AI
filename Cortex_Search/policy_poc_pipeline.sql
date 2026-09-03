-- ============================================================
-- POLICY DOCUMENTS POC — full pipeline
-- Paste each -- PHASE block into its own Snowflake Notebook cell.
-- Built for policy_poc_db.policy_poc schema, @policy_stg stage.
-- ============================================================


-- ============================================================
-- PHASE 0 — environment setup
-- ============================================================
CREATE DATABASE IF NOT EXISTS policy_poc_db;

CREATE OR REPLACE WAREHOUSE policy_poc_wh WITH
    WAREHOUSE_SIZE = 'X-SMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE;

USE WAREHOUSE policy_poc_wh;
USE DATABASE policy_poc_db;
CREATE SCHEMA IF NOT EXISTS policy_poc;
USE SCHEMA policy_poc;

CREATE OR REPLACE STAGE policy_stg
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

CREATE OR REPLACE RESOURCE MONITOR policy_poc_monitor WITH
    CREDIT_QUOTA = 50
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE policy_poc_wh SET RESOURCE_MONITOR = policy_poc_monitor;

-- confirm cross-region inference is enabled (needed for AI_EXTRACT/AI_CLASSIFY
-- if your account's home region doesn't natively support them)
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;
-- if value != 'ANY_REGION', run:
-- ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';

-- upload ANTICORRUPTION_ANTIBRIBERY_POLICY.pdf and Code_of_Conduct.pdf to
-- @policy_stg via Snowsight before continuing, then:
SELECT * FROM DIRECTORY(@policy_stg);


-- ============================================================
-- PHASE 1 — parse both PDFs with AI_PARSE_DOCUMENT (LAYOUT mode)
-- ============================================================
CREATE OR REPLACE TABLE raw_documents (
    relative_path       STRING,
    file_url             STRING,
    parsed_json          VARIANT,
    content_markdown     STRING,
    page_count           INT,
    parsed_at            TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO raw_documents (relative_path, file_url, parsed_json, content_markdown, page_count)
SELECT
    relative_path,
    file_url,
    parsed_json,
    parsed_json:content::STRING AS content_markdown,
    parsed_json:metadata:pageCount::INT AS page_count
FROM (
    SELECT
        relative_path,
        file_url,
        AI_PARSE_DOCUMENT(
            TO_FILE('@policy_stg', relative_path),
            {'mode': 'LAYOUT'}
        ) AS parsed_json
    FROM DIRECTORY(@policy_stg)
    WHERE relative_path ILIKE '%.pdf'
);

SELECT relative_path, page_count, LENGTH(content_markdown) AS md_length
FROM raw_documents;

-- worth doing once you have real output: inspect the markdown to see how
-- AI_PARSE_DOCUMENT rendered the numbered/lettered section headers, since
-- Phase 2's regex is written against an assumption about that shape and
-- may need adjusting once you can see it.
SELECT relative_path, LEFT(content_markdown, 3000) AS preview
FROM raw_documents;


-- ============================================================
-- PHASE 2a — chunk each document, markdown-header aware
-- ============================================================
-- One doc_id per source file, so downstream tables can join back cleanly.
CREATE OR REPLACE TABLE policy_documents (
    doc_id           STRING,
    entity_name      STRING,
    title            STRING,
    doc_type         STRING,
    amended_date     STRING,
    relative_path    STRING
);

-- Pulled from DIRECTORY(@policy_stg) rather than typed by hand, since the
-- Anti-Bribery file's actual name has two spaces in it
-- ("ANTICORRUPTION  ANTIBRIBERY POLICY.pdf") which is easy to mistype back
-- wrong and causes the later JOINs to silently return zero rows.
INSERT INTO policy_documents
SELECT 'doc_antibribery', 'Adani Enterprises Limited', 'Anti-Corruption & Anti-Bribery Policy', 'Policy', NULL, relative_path
FROM DIRECTORY(@policy_stg) WHERE relative_path ILIKE '%ANTICORRUPTION%'
UNION ALL
SELECT 'doc_codeofconduct', 'Adani Electricity Mumbai Ltd', 'Code of Conduct', 'Code of Conduct', '2009-01-23', relative_path
FROM DIRECTORY(@policy_stg) WHERE relative_path ILIKE '%Code_of_Conduct%';

SELECT * FROM policy_documents;

CREATE OR REPLACE TABLE policy_chunks (
    chunk_id         STRING DEFAULT UUID_STRING(),
    doc_id           STRING,
    relative_path    STRING,
    chunk_index      INT,
    chunk_text       STRING,
    headers          VARIANT
);

INSERT INTO policy_chunks (doc_id, relative_path, chunk_index, chunk_text, headers)
SELECT
    d.doc_id,
    r.relative_path,
    c.INDEX AS chunk_index,
    c.VALUE:chunk::STRING AS chunk_text,
    c.VALUE:headers AS headers
FROM raw_documents r
JOIN policy_documents d ON d.relative_path = r.relative_path,
LATERAL FLATTEN(
    INPUT => SNOWFLAKE.CORTEX.SPLIT_TEXT_MARKDOWN_HEADER(
        r.content_markdown,
        OBJECT_CONSTRUCT('#', 'header1', '##', 'header2', '###', 'header3'),
        1800,   -- chunk_size, CHARACTERS not tokens; policy prose runs long, keep chunks generous
        300     -- overlap, characters
    )
) c;

SELECT doc_id, COUNT(*) AS n_chunks FROM policy_chunks GROUP BY doc_id;


-- ============================================================
-- PHASE 2b — tier 0: deterministic extraction, zero AI credits
-- ============================================================

-- Section/TOC table. AI_PARSE_DOCUMENT rendered the Anti-Bribery policy's
-- contents page as a literal markdown pipe table ("|  1. | INTRODUCTION | 3  |"),
-- so we parse that directly rather than inferring structure from heading
-- levels (which turned out to be inconsistently nested in the source PDFs
-- and unreliable for this — see policy_chunks.headers for that finding).
CREATE OR REPLACE TABLE policy_sections AS
SELECT
    d.doc_id,
    TRIM(SPLIT_PART(s.value, '|', 2)) AS section_number,
    TRIM(SPLIT_PART(s.value, '|', 3)) AS title,
    TRY_TO_NUMBER(TRIM(SPLIT_PART(s.value, '|', 4))) AS page_number
FROM raw_documents r
JOIN policy_documents d ON d.relative_path = r.relative_path,
LATERAL SPLIT_TO_TABLE(r.content_markdown, '\n') s
WHERE d.doc_id = 'doc_antibribery'
  AND REGEXP_LIKE(TRIM(s.value), '^\\|\\s*\\d+\\.\\s*\\|.+\\|\\s*\\d+\\s*\\|$');

-- doc_codeofconduct's contents page needs its own pattern once we've seen
-- its real markdown — its source PDF lists sections as a plain numbered
-- list with no page-number column, so it likely didn't render as a table
-- the way Anti-Bribery's did. Run this and share the output before writing
-- that half:
-- SELECT SUBSTR(content_markdown, 1, 3000) FROM raw_documents WHERE relative_path ILIKE '%Code_of_Conduct%';

SELECT * FROM policy_sections ORDER BY TRY_TO_NUMBER(TRIM(section_number, '.'));

-- Contacts: plain regex over the whole document, no AI needed
CREATE OR REPLACE TABLE policy_contacts AS
SELECT
    d.doc_id,
    REGEXP_SUBSTR(r.content_markdown, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Z|a-z]{2,}') AS contact_email
FROM raw_documents r
JOIN policy_documents d ON d.relative_path = r.relative_path
WHERE REGEXP_SUBSTR(r.content_markdown, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Z|a-z]{2,}') IS NOT NULL;

-- Definitions for the Code of Conduct — moved to tier 0, deterministic.
-- Two AI_EXTRACT attempts on this document's Definitions section produced
-- opposite failure modes (spurious extra rows from lettered sub-lists,
-- then near-total omission once the prompt was tightened to avoid that).
-- That instability is a signal to stop iterating on prompting and use the
-- fact that this section is actually a very regular pattern:
-- "A.<n> 'Term' means/shall mean ..." — free and reliable to parse directly.
--
-- Known source irregularity, not a parsing bug: due to the source PDF's
-- two-column layout, A.10 and A.11 render as if they were continuations
-- "(d)" and "(e)" of A.9's sub-list rather than their own top-level
-- entries. The split below still catches them correctly since it matches
-- on the "A.<n> '" marker itself, but worth spot-checking those two rows
-- by eye after running this, given the source rendering around them is
-- genuinely irregular. Same caution for A.6, whose (a) item appears
-- twice in the source text.
CREATE OR REPLACE TABLE codeofconduct_definitions AS
WITH cleaned AS (
    SELECT
        REGEXP_REPLACE(
            content_markdown,
            '^\\s*(\\d{1,4}|adani|Electricity)\\s*$',
            '',
            1, 0, 'im'
        ) AS cleaned_markdown
    FROM raw_documents
    WHERE relative_path ILIKE '%Code_of_Conduct%'
),
region AS (
    SELECT
        SUBSTR(
            cleaned_markdown,
            POSITION('Part A' IN cleaned_markdown),
            POSITION('Part B' IN cleaned_markdown) - POSITION('Part A' IN cleaned_markdown)
        ) AS region_text
    FROM cleaned
),
delimited AS (
    SELECT REGEXP_REPLACE(region_text, '(A\\.\\d{1,2}\\s*'')', '~~~SPLIT~~~\\1') AS marked_text
    FROM region
),
entries AS (
    SELECT TRIM(s.value) AS entry
    FROM delimited, LATERAL SPLIT_TO_TABLE(marked_text, '~~~SPLIT~~~') s
    WHERE s.value LIKE 'A.%'
)
SELECT
    'doc_codeofconduct' AS doc_id,
    REGEXP_SUBSTR(entry, '^A\\.\\d{1,2}\\s*''([^'']+)''', 1, 1, 'e', 1) AS term,
    TRIM(REGEXP_REPLACE(entry, '^A\\.\\d{1,2}\\s*''[^'']+''\\s*(means|shall mean)?:?\\s*', '')) AS definition
FROM entries;

SELECT * FROM codeofconduct_definitions ORDER BY term;
-- ("Rs 5,00,000 or 25,000 shares or 1% of shareholding, whichever lower")
-- is a compound condition that doesn't decompose into a clean regex, and
-- typing the values in by hand after reading the PDF once isn't a pipeline
-- step, it's a one-off that goes stale the moment the document changes.
-- See Phase 4's policy_thresholds block.


-- ============================================================
-- PHASE 3 — tier 1: cheap classification, AI_CLASSIFY per chunk
-- ============================================================
-- Design note: nothing here is hardcoded into a SQL statement. Categories,
-- their descriptions, and the classification task itself all live in two
-- small config tables. Adding a category later, retiring one, or adding a
-- second classification domain entirely (e.g. document sensitivity, review
-- status, language) is a data change (INSERT/UPDATE) — not a code change.
-- This is the pattern to carry into prod: classification logic in the
-- pipeline shouldn't need a deploy every time the taxonomy changes.

-- One row per classification domain: what question is being asked, and how
-- (single label vs multi-label).
CREATE OR REPLACE TABLE classification_domains (
    domain              STRING,
    task_description    STRING,
    output_mode         STRING DEFAULT 'single'  -- 'single' or 'multi', passed straight to AI_CLASSIFY
);

INSERT INTO classification_domains (domain, task_description, output_mode) VALUES
    ('policy_topic', 'Classify a section of a corporate policy or code of conduct document by its primary topic.', 'single');

-- One row per (domain, category). is_active lets you retire a category
-- without losing the history of what it was ever applied to.
CREATE OR REPLACE TABLE classification_taxonomy (
    domain                  STRING,
    category                STRING,
    category_description    STRING,
    is_active                BOOLEAN DEFAULT TRUE
);

INSERT INTO classification_taxonomy (domain, category) VALUES
    ('policy_topic', 'Conflict of Interest'),
    ('policy_topic', 'Gifts and Entertainment'),
    ('policy_topic', 'Bribery and Corruption'),
    ('policy_topic', 'Insider Trading'),
    ('policy_topic', 'Financial and Accounting Integrity'),
    ('policy_topic', 'Work Ethics and Personal Conduct'),
    ('policy_topic', 'Health Safety Environment and Quality'),
    ('policy_topic', 'Ethics Management and Compliance Process'),
    ('policy_topic', 'Annexure or Blank Form');

-- ------------------------------------------------------------
-- Leaner alternative, for the leadership conversation: if the only thing
-- this classification is used for is keeping blank forms out of search
-- results (see Phase 5), a 9-way topic call is doing more work than the
-- task needs — a 2-way "is this real policy content or a template" call
-- is cheaper and likely more accurate, since a narrower decision is easier
-- for the model to get right. Switching to it is a data change too: run
-- the block below, then change the classify_domain variable further down
-- from 'policy_topic' to 'doc_status'. Both taxonomies can coexist.
-- ------------------------------------------------------------
-- INSERT INTO classification_domains (domain, task_description, output_mode) VALUES
--     ('doc_status', 'Classify whether this text is genuine policy content or a blank form, template, or annexure that should be excluded from search results.', 'single');
-- INSERT INTO classification_taxonomy (domain, category) VALUES
--     ('doc_status', 'Policy Content'),
--     ('doc_status', 'Blank Form or Annexure');

-- Classification results live in their own table, keyed by (chunk_id,
-- domain) rather than a column on policy_chunks. This means a second
-- classification domain (doc_status, sensitivity, whatever comes next)
-- doesn't require an ALTER TABLE — it's just another set of rows here.
CREATE OR REPLACE TABLE policy_chunk_classifications (
    chunk_id         STRING,
    domain           STRING,
    label            STRING,
    classified_at    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Which domain to run — this is the one line you change, not the AI_CLASSIFY
-- call itself, to switch between the 9-category and 2-category taxonomies
-- (or any future one added to the config tables above).
SET classify_domain = 'policy_topic';

INSERT INTO policy_chunk_classifications (chunk_id, domain, label)
SELECT
    c.chunk_id,
    $classify_domain,
    AI_CLASSIFY(
        c.chunk_text,
        (SELECT ARRAY_AGG(category) FROM classification_taxonomy
         WHERE domain = $classify_domain AND is_active = TRUE),
        OBJECT_CONSTRUCT(
            'task_description',
            (SELECT task_description FROM classification_domains WHERE domain = $classify_domain)
        )
    ):labels[0]::STRING AS label
FROM policy_chunks c;

SELECT label, COUNT(*) FROM policy_chunk_classifications
WHERE domain = $classify_domain
GROUP BY label ORDER BY 2 DESC;

-- check spend so far before moving to the more expensive tier
-- (CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY is Snowflake's older view and is
-- no longer updated; CORTEX_AI_FUNCTIONS_USAGE_HISTORY is current. It also
-- has no flat TOKENS column — token counts live inside the METRICS array —
-- so this reports credits and call count, which is what actually matters
-- for budget tracking against the resource monitor.)
SELECT function_name, model_name, SUM(credits) AS credits_used, COUNT(*) AS calls
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
WHERE start_time >= DATEADD(day, -1, CURRENT_TIMESTAMP())
GROUP BY function_name, model_name
ORDER BY credits_used DESC;


-- ============================================================
-- PHASE 4 — tier 2: structured extraction, AI_EXTRACT / AI_SENTIMENT
-- ============================================================

-- Definitions: term/definition pairs, whole-document call (not per chunk).
-- IMPORTANT: AI_EXTRACT's JSON schema only accepts three sub-object shapes —
-- a string, a list of strings, or a "table" (object of PARALLEL ARRAYS,
-- one per column). Array-of-objects (what an earlier version of this used)
-- silently produces no usable rows, since it isn't a shape AI_EXTRACT
-- actually supports. Rows are reassembled by flattening each column array
-- and joining on .INDEX, matching Snowflake's own documented pattern.
--
-- Two known issues on the 64-page Code of Conduct:
-- (1) A real bug in the previous version of this filter: `value IS NOT
--     NULL` tests the raw VARIANT, and a VARIANT holding JSON null is
--     still "a value" as far as SQL NULL-checking is concerned — it is
--     NOT the same as SQL NULL. The filter below casts to STRING first,
--     which correctly collapses JSON null to real SQL NULL before the
--     NULL check runs.
-- (2) A genuine schema limitation, not fully fixable by prompting alone:
--     several definitions (Connected Persons, Deemed Connected Persons,
--     Designated Employee) continue into a lettered sub-list, and the
--     flat "table" schema has no way to represent that nesting. The model
--     was truncating the definition at the list boundary and spraying the
--     list items out as spurious extra rows. The description below
--     explicitly asks it to fold sub-list content into one string instead.
--     Worth checking on re-run whether this actually recovers the full
--     "Connected Persons" definition, or just stops the spurious rows
--     while still truncating content — those are different outcomes and
--     only one of them is actually fixed.
-- Scoped to Anti-Bribery only now — this call has produced the correct
-- 5 definitions identically across three separate runs, so it's earned
-- trust for this document. The Code of Conduct's definitions come from
-- codeofconduct_definitions (Phase 2b, deterministic) instead, unioned in
-- below, after the instability found when this same call ran against it.
CREATE OR REPLACE TABLE policy_definitions AS
SELECT
    x.doc_id,
    t.value::STRING AS term,
    def.value::STRING AS definition
FROM (
    SELECT
        d.doc_id,
        AI_EXTRACT(
            text => r.content_markdown,
            responseFormat => {
                'schema': {
                    'type': 'object',
                    'properties': {
                        'definitions': {
                            'description': 'Only genuine defined terms, typically stated as "X means Y" or "X is Y" or "X shall mean Y", usually found in a dedicated Definitions section. Do NOT include items from numbered or lettered lists that describe obligations, procedures, exceptions, or examples — only include an item if the document is explicitly defining what that term means. If a definition continues into a lettered or numbered sub-list (e.g. "(a)...", "(b)..."), include the FULL content of every sub-item concatenated into the single definition string for that one term — never create a separate row for a sub-item.',
                            'type': 'object',
                            'column_ordering': ['term', 'definition'],
                            'properties': {
                                'term': {'type': 'array', 'description': 'the defined term'},
                                'definition': {'type': 'array', 'description': 'the complete definition text for that term, including all sub-clauses folded in as one string'}
                            }
                        }
                    }
                }
            }
        ):response AS extracted
    FROM raw_documents r
    JOIN policy_documents d ON d.relative_path = r.relative_path
    WHERE d.doc_id = 'doc_antibribery'
) x,
LATERAL FLATTEN(INPUT => x.extracted:definitions:term) t,
LATERAL FLATTEN(INPUT => x.extracted:definitions:definition) def
WHERE t.INDEX = def.INDEX
  AND def.value::STRING IS NOT NULL
  AND TRIM(def.value::STRING) != '';

-- combine with the deterministic Code of Conduct definitions from Phase 2b
INSERT INTO policy_definitions
SELECT doc_id, term, definition FROM codeofconduct_definitions;

SELECT * FROM policy_definitions ORDER BY doc_id, term;

-- Roles and responsibilities — same table-shape fix as definitions above.
CREATE OR REPLACE TABLE policy_roles AS
SELECT
    x.doc_id,
    rn.value::STRING AS role_name,
    resp.value::STRING AS responsibilities
FROM (
    SELECT
        d.doc_id,
        AI_EXTRACT(
            text => r.content_markdown,
            responseFormat => {
                'schema': {
                    'type': 'object',
                    'properties': {
                        'roles': {
                            'description': 'Every named role or office mentioned in this policy (e.g. Compliance Officer, CEO, Ethics Officer) and a condensed summary of what the document says they are responsible for',
                            'type': 'object',
                            'column_ordering': ['role_name', 'responsibilities'],
                            'properties': {
                                'role_name': {'type': 'array', 'description': 'name of the role or office'},
                                'responsibilities': {'type': 'array', 'description': 'condensed summary of stated responsibilities'}
                            }
                        }
                    }
                }
            }
        ):response AS extracted
    FROM raw_documents r
    JOIN policy_documents d ON d.relative_path = r.relative_path
) x,
LATERAL FLATTEN(INPUT => x.extracted:roles:role_name) rn,
LATERAL FLATTEN(INPUT => x.extracted:roles:responsibilities) resp
WHERE rn.INDEX = resp.INDEX
  AND resp.value::STRING IS NOT NULL
  AND TRIM(resp.value::STRING) != '';

SELECT * FROM policy_roles;

-- Thresholds: genuine extraction, not hand-typed. Quantitative rules like
-- pre-clearance limits, disclosure triggers, and holding periods, including
-- compound conditions the source text states as "whichever is lower".
-- Same table-shape correction as the two blocks above — three parallel
-- columns this time.
--
-- KNOWN LIMITATION, found in testing, worth carrying into the production
-- plan: on the Code of Conduct (64 pages), this call returned only 1 of
-- roughly 5 known thresholds — the one it found was accurate, so this is
-- a recall problem, not an accuracy problem. This is the third time a
-- whole-document AI_EXTRACT call has been unreliable specifically on this
-- document (spurious rows and near-omission on two definitions attempts,
-- now under-recall here) — pattern seems to be: long document + many
-- scattered targets with no natural entity to anchor around (contrast
-- with policy_roles, which worked well because it's anchored around a
-- small number of named roles). For production, the likely fix is
-- section- or chunk-scoped extraction with results unioned together,
-- rather than one call against the whole document. Not fixing this now —
-- prioritising a running end-to-end prototype first, per plan.
CREATE OR REPLACE TABLE policy_thresholds AS
SELECT
    x.doc_id,
    de.value::STRING AS description,
    va.value::STRING AS value_text,
    so.value::STRING AS source_section
FROM (
    SELECT
        d.doc_id,
        AI_EXTRACT(
            text => r.content_markdown,
            responseFormat => {
                'schema': {
                    'type': 'object',
                    'properties': {
                        'thresholds': {
                            'description': 'Every specific numeric rule, limit, deadline, or threshold stated in this policy document (e.g. holding periods, disclosure limits, pre-clearance thresholds, filing deadlines). Preserve compound conditions such as "whichever is lower" exactly as stated rather than simplifying them.',
                            'type': 'object',
                            'column_ordering': ['description', 'value_text', 'source_section'],
                            'properties': {
                                'description': {'type': 'array', 'description': 'short label for what this threshold governs'},
                                'value_text': {'type': 'array', 'description': 'the value(s) and unit(s), verbatim from the text'},
                                'source_section': {'type': 'array', 'description': 'the section number or heading this was found under, if identifiable'}
                            }
                        }
                    }
                }
            }
        ):response AS extracted
    FROM raw_documents r
    JOIN policy_documents d ON d.relative_path = r.relative_path
) x,
LATERAL FLATTEN(INPUT => x.extracted:thresholds:description) de,
LATERAL FLATTEN(INPUT => x.extracted:thresholds:value_text) va,
LATERAL FLATTEN(INPUT => x.extracted:thresholds:source_section) so
WHERE de.INDEX = va.INDEX AND va.INDEX = so.INDEX
  AND va.value::STRING IS NOT NULL
  AND TRIM(va.value::STRING) != '';

SELECT * FROM policy_thresholds;

-- Obligations: lettered/numbered "must/must not" clauses, tagged by topic.
-- Same table-shape correction as the three blocks above.
--
-- KNOWN LIMITATION, found in testing, worth carrying into the production
-- plan: this call returned the document's DEFINITIONS relabelled as
-- obligations (e.g. "Bribery means X" tagged prohibited), rather than the
-- genuine imperative clauses like section 4's lettered "what is not
-- acceptable" list. Different failure mode from the thresholds under-
-- recall above — this one found content, but the wrong content, because
-- "a term describing something bad" and "an actual prohibition clause"
-- weren't distinguished clearly enough in the schema description. A
-- tighter description (explicitly: skip anything that's just naming or
-- defining a concept; only include sentences that actually instruct
-- someone to do or not do something) is the likely fix, worth testing
-- before deciding whether this needs chunk-scoped extraction like the
-- thresholds finding suggests. Not fixing this now — prioritising a
-- running end-to-end prototype first, per plan.
CREATE OR REPLACE TABLE policy_obligations AS
SELECT
    x.doc_id,
    tp.value::STRING AS topic,
    tx.value::STRING AS obligation_text,
    ty.value::STRING AS obligation_type
FROM (
    SELECT
        d.doc_id,
        AI_EXTRACT(
            text => r.content_markdown,
            responseFormat => {
                'schema': {
                    'type': 'object',
                    'properties': {
                        'obligations': {
                            'description': 'Every explicit rule stated as a prohibition ("must not", "shall not", "is not acceptable") or requirement ("must", "shall") in this policy',
                            'type': 'object',
                            'column_ordering': ['topic', 'obligation_text', 'obligation_type'],
                            'properties': {
                                'topic': {'type': 'array', 'description': 'short topic tag, e.g. gifts, insider_trading, conflict_of_interest'},
                                'obligation_text': {'type': 'array', 'description': 'the rule itself'},
                                'obligation_type': {'type': 'array', 'description': 'either prohibited or required'}
                            }
                        }
                    }
                }
            }
        ):response AS extracted
    FROM raw_documents r
    JOIN policy_documents d ON d.relative_path = r.relative_path
) x,
LATERAL FLATTEN(INPUT => x.extracted:obligations:topic) tp,
LATERAL FLATTEN(INPUT => x.extracted:obligations:obligation_text) tx,
LATERAL FLATTEN(INPUT => x.extracted:obligations:obligation_type) ty
WHERE tp.INDEX = tx.INDEX AND tx.INDEX = ty.INDEX
  AND tx.value::STRING IS NOT NULL
  AND TRIM(tx.value::STRING) != '';

SELECT * FROM policy_obligations;

-- spend check again — this is the expensive tier, worth confirming before Phase 5
SELECT function_name, model_name, SUM(credits) AS credits_used, COUNT(*) AS calls
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
WHERE start_time >= DATEADD(day, -1, CURRENT_TIMESTAMP())
GROUP BY function_name, model_name
ORDER BY credits_used DESC;


-- ============================================================
-- PHASE 5 — Cortex Search service for the chat fallback tab
-- ============================================================
-- Excludes annexure/blank-form chunks so a blank acceptance letter
-- never surfaces as if it answered a real question. chunk_topic now comes
-- from policy_chunk_classifications (domain = 'policy_topic') rather than
-- a column on policy_chunks — swap the WHERE below to 'doc_status' if you
-- switched to the leaner two-category taxonomy in Phase 3.
--
-- header1/2/3 are flattened out of policy_chunks.headers (a VARIANT) into
-- plain STRING attributes here, rather than exposing the VARIANT itself as
-- an attribute — string attributes are the proven-working pattern (doc_id,
-- chunk_topic already work this way); untested whether Cortex Search
-- attributes handle a VARIANT/object attribute the same way, so flattening
-- at the SQL layer avoids introducing that as an unknown right before a
-- live demo. This is what lets the app show which section of the document
-- an answer came from, for cross-validation against the source PDF.
CREATE OR REPLACE CORTEX SEARCH SERVICE policy_search_svc
ON chunk_text
ATTRIBUTES doc_id, chunk_topic, header1, header2, header3
WAREHOUSE = policy_poc_wh
TARGET_LAG = '1 day'
AS
SELECT
    c.chunk_id,
    c.doc_id,
    c.chunk_text,
    cl.label AS chunk_topic,
    c.headers:header1::STRING AS header1,
    c.headers:header2::STRING AS header2,
    c.headers:header3::STRING AS header3
FROM policy_chunks c
LEFT JOIN policy_chunk_classifications cl
    ON cl.chunk_id = c.chunk_id AND cl.domain = 'policy_topic'
WHERE cl.label IS NULL OR cl.label != 'Annexure or Blank Form';

-- quick test — confirm header1/2/3 come back populated
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'policy_poc_db.policy_poc.policy_search_svc',
    '{"query": "what is the minimum holding period for securities", "columns": ["chunk_text", "doc_id", "header1", "header2", "header3"], "limit": 3}'
);
