# Policy Documents Structured Extraction — PoC Findings & Production Readiness

**Scope of this document:** This PoC was built against two sample policy documents (Adani Enterprises Limited's Anti-Corruption & Anti-Bribery Policy, and Adani Electricity Mumbai Ltd's Code of Conduct) purely as representative test material. Nothing about the findings below is specific to Adani — every finding is about the *mechanics* of extracting structured data from policy-style PDFs on Snowflake Cortex, and should be read as generalising to any future policy or compliance document this pattern gets applied to.

**Purpose:** To record what we built, what we tried and reverted, why, and what that implies for the gap between "this works as a proof of concept" and "this is production-ready." A PoC's job is to prove technical feasibility. It does not — and this document argues should not be expected to — prove reliability, maintainability, or business fitness. Those are separate, larger pieces of work, laid out below.

---

## 1. What Was Built

A pipeline on Snowflake Cortex that takes policy PDFs from a stage through to a browsable Streamlit application:

`AI_PARSE_DOCUMENT` (layout-aware parsing) → markdown-aware chunking → a three-tier extraction economy (deterministic regex where the source allows it, cheap classification for filtering, LLM extraction only where genuinely needed) → Cortex Search for open-ended chat → a Streamlit app surfacing thresholds, definitions, roles, obligations, and a search-backed chat fallback.

The three-tier principle — regex first, classification second, generative extraction last — held up as the right design throughout. What changed repeatedly, and is the subject of this document, was *where the line falls* between the tiers for a given piece of content.

---

## 2. Design Decisions: What We Tried, What We Reverted, and Why

This section is chronological. Each entry follows the shape: what we did → what we observed → what we changed → the generalisable lesson.

### 2.1 Scope: two document types considered, one dropped

We initially scoped this exercise around both FOMC meeting minutes and internal policy documents, since both were floated as candidate use cases. Once real policy PDFs were available, the business decision was made to drop FOMC entirely and focus on policy documents only. **Lesson:** scope narrowed based on actual business priority once real documents were in hand, not on technical difficulty — worth remembering that the *next* document type this gets applied to should get the same explicit scoping decision, not an assumption that "the pipeline already works, just point it at anything."

### 2.2 Trial account restrictions

Snowflake trial accounts without a payment method on file block Cortex AI Functions outright, not just rate-limit them. This wasn't discoverable from documentation alone — it surfaced as a runtime error (`AI_PARSE_DOCUMENT is not available for trial accounts`) and required web research to confirm the cause and the fix (adding a payment method converts to on-demand billing while preserving the trial credit balance). **Lesson:** environment/account-tier restrictions on AI features are a real, undocumented-until-you-hit-it risk for any new Snowflake environment — budget time for this discovery step whenever standing up a new account or sandbox, including whatever environment production ultimately runs in.

### 2.3 Hardcoded filename in document registration → dynamic lookup

The Anti-Bribery PDF's actual filename contained two spaces (`ANTICORRUPTION  ANTIBRIBERY POLICY.pdf`), not the underscore-separated name that seemed natural to type. A hardcoded `INSERT` using the assumed filename silently produced zero matching rows in a downstream `JOIN` — no error, just quietly incomplete data. Fixed by pulling `relative_path` directly from `DIRECTORY(@stage)` rather than retyping it. **Lesson:** any place a filename, column name, or identifier is typed by hand rather than read from the system is a latent silent-failure risk. This class of bug produces *no error message* — it just returns fewer rows than expected, which is far more dangerous than a hard failure because it's easy to miss.

### 2.4 `SPLIT_TEXT_MARKDOWN_HEADER` argument type

An early call passed the header hierarchy as an `ARRAY` of `[marker, label]` pairs; the function requires an `OBJECT` (built with `OBJECT_CONSTRUCT`). Also corrected an internal comment that mislabelled `chunk_size` as a token count when it's actually a character count. **Lesson:** minor, but representative of a broader pattern this session surfaced repeatedly — Cortex function signatures should be verified against current documentation at time of writing, not assumed from memory or from how a similarly-named function might work elsewhere.

### 2.5 Section/TOC extraction: three approaches, in order of decreasing assumption

1. **First attempt:** a regex guessing at how numbered/lettered headers ("1. INTRODUCTION", "(I) Policy on...") might render in `AI_PARSE_DOCUMENT`'s markdown output, written *before* the actual output had been inspected. Returned zero rows.
2. **Second attempt:** using the markdown header hierarchy (`#`, `##`, `###`) that the chunking step had already parsed. Inspection revealed this was structurally unreliable — the source PDF used bold text for concepts like "Respect," "Fairness," "Trust" that are visually distinct but not a true heading hierarchy, so each became its own top-level header, and worse, once no new top-level header appeared, the chunker kept carrying forward a stale label (a chunk from the "Commitments" section was mislabelled under a "Caring" header several pages after "Caring" had actually ended).
3. **Final approach:** actually reading the real parsed markdown revealed `AI_PARSE_DOCUMENT` had rendered the Anti-Bribery policy's contents page as a literal markdown pipe table (`| 1. | INTRODUCTION | 3 |`) — directly parseable with `SPLIT_PART`, free, and authoritative, since it's the document's own real table of contents rather than an inferred structure.

**Lesson:** the single highest-leverage debugging step in this entire session was *looking at the actual parsed output before writing extraction logic against it*, rather than assuming a shape and writing code to match the assumption. This should be a standing first step for any new document type, not something reached for only after two failed attempts.

### 2.6 Hand-typed thresholds → genuine extraction

An early version of `policy_thresholds` was populated by a hardcoded `INSERT`, with the values obtained by a human (in this case, the AI assistant) reading the source PDF once and typing the numbers in. When questioned, this was recognised as a real design flaw, not an acceptable placeholder: it doesn't scale to a second document, goes silently stale if the source document is amended, and misrepresents what the pipeline actually does if shown to anyone as "automated extraction." Replaced with a genuine `AI_EXTRACT` call. **Lesson:** a hardcoded value that happens to be correct today is a worse artifact than an admittedly-incomplete automated extraction, because it looks finished while being fundamentally non-reproducible. Any manually-entered "extracted" fact in a pipeline meant to demonstrate automation should be treated as a defect, not a shortcut.

### 2.7 Hardcoded classification categories → config-driven taxonomy

`AI_CLASSIFY`'s category list was initially a literal array inside the classification `UPDATE` statement. When asked to eliminate hardcoding for production-readiness, this was redesigned into two config tables (`classification_domains`, `classification_taxonomy`) plus a normalised results table (`policy_chunk_classifications`, keyed by chunk and domain rather than a column on the chunks table). The practical effect: adding, retiring, or renaming a category is now a data change (`INSERT`/`UPDATE`), and adding an entirely new classification dimension in the future (document sensitivity, review status, language) requires no schema change at all — just new rows in the config tables. **Lesson:** the difference between "PoC-hardcoded" and "production-ready" is often not more code, it's *where a piece of logic is allowed to live* — moving a business-owned decision (what are our categories?) out of SQL literals and into a table that business can actually see and edit is a structural improvement, not a cosmetic one.

### 2.8 `AI_EXTRACT` schema shape: a genuine platform constraint, not a bug

The single most consequential technical finding of this session: `AI_EXTRACT`'s JSON schema **only accepts three sub-object shapes** — a plain string, a list of strings, or a "table" (an object whose properties are parallel arrays representing columns). An array-of-objects schema (e.g., a `definitions` array where each element is `{term, definition}`) is **not supported**, and using it doesn't produce a clear error — it silently returns unusable output, which surfaced as a table that created successfully but came back empty. All four extraction tables (definitions, roles, thresholds, obligations) had to be rewritten to use parallel arrays reassembled by flattening each column and joining on array index. **Lesson:** this is not document-specific — it is a hard constraint of the platform function itself, and applies to any future `AI_EXTRACT` schema design, for any document. It should be treated as a standing design rule: **never** design an `AI_EXTRACT` schema around nested objects inside an array; always design around parallel column arrays.

### 2.9 VARIANT `NULL` vs. JSON `null`: a genuine Snowflake gotcha

A filter intended to drop malformed extraction rows (`value IS NOT NULL`) did not work, because the value in question was a `VARIANT` column *containing* a JSON `null` — which Snowflake treats as "a value is present" for `NULL`-checking purposes, not as SQL `NULL`. The fix was to cast to a scalar type (`value::STRING`) before checking nullity, since casting a JSON `null` correctly collapses it to true SQL `NULL`. **Lesson:** this is a documented, known Snowflake behaviour (not unique to this pipeline) that applies anywhere `VARIANT`/semi-structured data from `FLATTEN`, `AI_EXTRACT`, `AI_PARSE_DOCUMENT`, or similar functions is filtered on nullity. Any future pipeline handling semi-structured Cortex output should cast-then-check as a standing rule, not an occasional fix.

### 2.10 Code of Conduct definitions: two divergent AI failures, then a return to determinism

This is the clearest illustration in the whole session of where the tiering strategy should have been applied from the start, and wasn't:

- **Attempt 1** (broad extraction instruction): correctly found the real definitions, but *also* fabricated spurious extra rows — every lettered item in *any* numbered list elsewhere in the 64-page document (procedural lists, obligation lists) got treated as if it were its own defined term with no definition.
- **Attempt 2** (tightened instruction, explicitly excluding procedural/obligation lists): overcorrected so severely that it dropped nearly the entire real Definitions section too, because that section is *itself* formatted as a numbered list, and the tightened instruction couldn't distinguish "numbered list that's actually definitions" from "numbered list that's actually obligations."
- **Resolution:** rather than attempt a third prompt, the document's real Definitions section was inspected directly and found to follow an extremely regular pattern (`A.<n> 'Term' means...`), fully regex-extractable, free, and immune to the instability just observed twice. Once implemented, all content was preserved correctly, including the full multi-line sub-lists that both AI attempts had either fragmented or dropped.

**Lesson, generalised:** two consecutive AI-extraction attempts failing in *opposite directions* (over-inclusive, then over-exclusive) on the same target is a strong signal to stop iterating on the prompt and check whether the source has enough structural regularity for a deterministic approach instead — not to try a third, more elaborate prompt. This is a decision rule worth writing into any future extraction playbook: **two divergent failures → switch tiers, don't keep tuning.**

### 2.11 Source-document rendering irregularities (not pipeline bugs)

Two genuine irregularities were found in how the source PDF's layout rendered into markdown, unrelated to any code written here:
- A two-column page layout caused two definitions (`A.10`, `A.11`) to render as if they were lettered continuations (`(d)`, `(e)`) of the *previous* definition's sub-list, purely due to reading-order artifacts.
- One definition's sub-list (`A.6`) contained a duplicated line label.

Both are cosmetic (no content was lost) and were left as known, documented imperfections rather than chased with further regex iteration. **Lesson:** multi-column PDF layouts will produce reading-order artifacts in any parsing pipeline, not just this one. A production ingestion process needs an explicit spot-check step for newly onboarded documents, specifically looking for this failure class, rather than assuming a pipeline validated on one document's layout will render every future document's layout cleanly.

### 2.12 Thresholds and obligations: two distinct, currently unresolved limitations

Both surfaced only once real extraction was run (not during design), and both are documented directly in the pipeline code as open items:

- **Thresholds:** whole-document extraction against the 64-page Code of Conduct returned only 1 of roughly 5 known real thresholds. The one result returned was accurate — this is a **recall** problem, not an accuracy problem.
- **Obligations:** the same call returned the document's *definitions*, relabelled as "prohibited" obligations, rather than the genuine imperative clauses found elsewhere in the document. This is a **targeting** problem — the model conflated "a term describing something bad" with "an actual rule forbidding an action."

Both are left open, deliberately, in favour of reaching a working end-to-end prototype first. **Lesson:** both problems share a pattern distinct from what worked well (roles, which succeeded because it's organised around a small number of named entities that facts can be gathered around). Thresholds and obligations are diffuse — many scattered instances, no natural anchor — and whole-document extraction appears markedly less reliable for that shape of task than for the entity-anchored shape. This is the clearest concrete argument in this whole document for why **chunk- or section-scoped extraction with results unioned together**, rather than one call against an entire long document, is likely the real fix — untested here, but strongly suggested by the pattern.

### 2.13 Miscellaneous technical corrections

- `CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY` is a deprecated, frozen view; `CORTEX_AI_FUNCTIONS_USAGE_HISTORY` is current and has a different column shape (no flat `TOKENS` column; token counts live inside a `METRICS` array, while `CREDITS` is a genuine top-level column).
- A regex combining an inline `(?im)` flag group with a trailing `\n?` failed to compile; the fix was to pass flags through `REGEXP_REPLACE`'s dedicated parameters argument rather than embedding them in the pattern string.
- A Streamlit column reference (`source_note`) went stale after an upstream table rewrite renamed the column to `source_section`, and wasn't caught until the app failed at runtime.

**Lesson, generalised from all three:** Cortex documentation and function behaviour changed *during the course of this single project* (the usage-history view rename, for instance) — a production system built on these functions needs a process for periodically re-verifying pipeline code against current documentation, not an assumption that code verified once stays correct indefinitely. The Streamlit column drift is a smaller version of the same problem: any time an upstream schema changes, every downstream consumer needs to be checked, not just the one that happened to be top of mind.

---

## 3. What This Means for Production Readiness

Every finding above was discovered on **two documents**, both already read multiple times by a human during debugging, in a session with no time pressure and no real users. That is about as favourable a condition as this pattern will ever be tested under. At production scale — dozens or hundreds of real policy documents, ongoing amendments, real users relying on the app's answers — the same failure classes will recur, but without the benefit of someone manually reading every table's output before trusting it.

A PoC proves technical feasibility. It does not prove:

- **Reliability at scale** — every extraction failure found here was caught because a human looked at the row count and the content by eye. Production needs automated quality checks (row-count sanity bounds, spot-check sampling, confidence scoring) that don't depend on someone remembering to look.
- **Graceful failure** — none of the current pipeline code handles `AI_EXTRACT` returning malformed or unexpected output gracefully; it either silently produces bad rows (as seen repeatedly) or the query errors outright. Production needs defined behaviour for "extraction failed or looks wrong" — not just "extraction succeeded."
- **Change management** — nothing in this pipeline currently handles what happens when a source document is amended. Does the old version get archived? Does the app show a version history? Who triggers re-ingestion, and how quickly does the app need to reflect a change? None of this was in scope for a PoC and all of it is required for production.
- **Ownership of the taxonomy and schema** — the classification categories, the four structured tables (definitions/roles/thresholds/obligations), and what counts as "worth extracting" were all engineering guesses made to demonstrate the pattern. None of them were validated against what the actual business users of this app need. This is the single largest gap between PoC and production, and it's addressed directly in Section 4.
- **Security and access review** — these are compliance documents. Structured data derived from them likely needs the same governance (row-level security, audit logging, access review) as the source PDFs, and that has not been designed here at all.
- **Cost governance at scale** — the resource monitor and manual usage-history queries used in this PoC are adequate for two documents run interactively. A production system ingesting new or amended documents on an ongoing basis needs proper cost monitoring and alerting, not a query someone remembers to run.

None of this is a criticism of the PoC — it did exactly what a PoC should do. It's the honest accounting of what's still ahead, and it's substantial: closer to a second, larger project than a cleanup pass on this one.

---

## 4. Decisions and Responsibilities That Belong to the Business, Not Engineering

A recurring theme across Section 2 is that engineering made reasonable-looking guesses — at the classification taxonomy, at which four fields mattered enough to extract, at what counted as noise worth excluding — because no one else had defined them yet. For production, these need to be business decisions, made explicitly and revisited on a defined cadence, not engineering assumptions baked into code. Specifically:

1. **The classification taxonomy.** Engineering chose nine topic categories (Conflict of Interest, Gifts and Entertainment, etc.) based on skimming the two sample documents. Business/compliance should own this list — what categories actually matter for how the organisation thinks about its policies — and the config-table design (Section 2.7) means this can now be handed to them as an editable list, not a code change request.

2. **What gets excluded from the app entirely.** Engineering excluded blank forms and annexures from search results, based on an engineering judgement that they'd clutter results. Business/legal may have other exclusion needs entirely — internal-only clauses, anything under legal hold, content that shouldn't be surfaced to certain audiences — and these need to be explicitly specified, not inferred.

3. **Which structured fields actually matter.** The four tables built here (definitions, roles, thresholds, obligations) were an engineering guess at what would be useful for a compliance-handbook-style app. The actual answer depends on how compliance teams, legal, and end users actually consult these documents today — what questions do they currently answer by reading the PDF manually, and would a structured field actually replace that, or just supplement it. This needs direct input from the people who'd use the app, not an assumption.

4. **Change management ownership.** When a policy is amended, someone needs to own triggering re-ingestion, and a decision is needed on whether the app shows only the current version, or a version history. This is a process and ownership question, not a technical one — engineering can build whatever process is specified, but can't specify it.

5. **Sign-off on extracted content before it's user-facing.** Given this is compliance-sensitive material, a wrong "threshold" or a mis-extracted "obligation" surfaced confidently in an app is itself a compliance risk — arguably worse than the PDF being hard to search, since it looks authoritative. Business/legal should define what review or approval step, if any, extracted structured data needs before end users see it, and what the acceptable error tolerance is. "Good enough for a leadership demo" and "good enough to be relied on instead of reading the source PDF" are different bars, and only the business side can say which one is required.

6. **Access scope.** Who should see this app — is it scoped by entity, business unit, role, or open to all employees? This affects both the Streamlit app's design and any row-level security needed on the underlying tables.

Put simply: the technical pattern is proven. What's not yet defined is *what the business actually wants built on top of it*, and every open item above is a question only the business can answer — engineering can only guess, and guessing is exactly what produced most of the rework documented in Section 2.

---

## 5. Chronological Decision Log

| # | Decision | Reason at the time | Reverted? | Reason for reversal | Generalisable lesson |
|---|---|---|---|---|---|
| 1 | Two-corpus scope (FOMC + policy) | Both floated as candidates | Yes | Business chose policy-only | Scope by business priority, not technical convenience |
| 2 | Hardcoded Anti-Bribery filename | Seemed like the obvious name | Yes | Real filename had unexpected spacing; silent join failure | Read identifiers from the system, never type them by hand |
| 3 | `SPLIT_TEXT_MARKDOWN_HEADER` called with ARRAY arg | Assumed signature | Yes | Function requires OBJECT | Verify function signatures against current docs |
| 4 | `policy_sections` via guessed header regex | No real output inspected yet | Yes | Zero rows returned | Inspect real output before writing extraction logic |
| 5 | `policy_sections` via markdown header hierarchy | Seemed like the natural structure source | Yes | Header nesting unreliable in source PDF | Don't trust inferred structure over the document's own literal structure |
| 6 | `policy_sections` via literal markdown TOC table | Found by inspecting real parsed output | No (final) | — | The document's own rendered structure, when present, beats any inferred pattern |
| 7 | Hand-typed threshold values | Fast placeholder | Yes | Not reproducible, not scalable, misrepresents automation | Manually-entered "extracted" data is a defect, not a shortcut |
| 8 | Hardcoded `AI_CLASSIFY` category array | Simplest first pass | Yes | Not scalable, business can't edit code | Business-owned decisions belong in data, not SQL literals |
| 9 | `chunk_topic` as a column on `policy_chunks` | Simplest schema | Yes | New classification domains would need `ALTER TABLE` | Normalise for extensibility before it's needed, not after |
| 10 | `AI_EXTRACT` array-of-objects schema | Assumed shape, seemed natural | Yes | Not a supported shape; silently empty output | `AI_EXTRACT` only supports string / list / parallel-array table |
| 11 | `value IS NOT NULL` filter on VARIANT | Assumed standard NULL-check semantics | Yes | JSON `null` in a VARIANT isn't SQL NULL | Cast before NULL-checking semi-structured data |
| 12 | Code of Conduct definitions via broad AI_EXTRACT prompt | Reuse the working Anti-Bribery approach | Yes | Spurious extra rows from unrelated numbered lists | Whole-document extraction is noisier on longer, list-heavy documents |
| 13 | Code of Conduct definitions via tightened AI_EXTRACT prompt | Attempt to fix #12 | Yes | Overcorrected; dropped most real definitions too | Two divergent AI failures → switch tiers, don't keep tuning the prompt |
| 14 | Code of Conduct definitions via regex | Section found to be highly regular | No (final) | — | Prefer deterministic extraction wherever the source structure allows it |
| 15 | `CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY` for spend checks | Assumed still current | Yes | View deprecated; wrong column assumed | Re-verify Cortex reference views against current docs |
| 16 | Whole-document extraction for thresholds/obligations | Consistent with other tables | Open / documented, not yet resolved | Recall and targeting failures found on the longer document | Diffuse, scattered targets likely need chunk-scoped extraction, not whole-document |

---

## 6. Summary for Leadership

The pattern works. Snowflake Cortex can reliably parse, chunk, classify, and structure policy documents, and the resulting app is genuinely useful for the content it handles well — which is most of it. What this PoC surfaced, honestly and repeatedly, is that **the reliability of AI-based extraction is not uniform** — it depends heavily on document length, on whether extraction targets are anchored around a small number of named entities versus scattered diffusely through the text, and on whether the source has enough literal structure to skip AI extraction entirely in favour of free, deterministic parsing. Getting this right for real production use requires: business ownership of the taxonomy and schema (Section 4), engineering investment in automated quality checks and graceful failure handling (Section 3), and a deliberate design decision — informed directly by this PoC's findings — to scope extraction calls to sections or chunks rather than whole documents wherever targets are diffuse (Section 2.12). None of that is a rebuild; it's a second, well-scoped phase of work building directly on what's proven here.
