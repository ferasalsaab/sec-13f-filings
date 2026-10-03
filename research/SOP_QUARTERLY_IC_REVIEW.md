# Quarterly Institutional Capital Intelligence Review
## Standard Operating Procedure

**Document:** SOP-ICI-001  
**Owner:** Capital Allocation Research  
**Frequency:** Quarterly  
**Standard run date:** 20 February, 20 May, 20 August, 20 November  
**System:** Institutional Capital Intelligence Stack — Reports 01–10  
**Status:** Controlled operating procedure

---

## 1. Purpose

This SOP governs the quarterly operation of the Institutional Capital
Intelligence research stack.

The system converts observable SEC Form 13F disclosures into a governed
capital-allocation research process covering:

1. capital universe;
2. capital concentration;
3. manager universe;
4. manager architecture;
5. manager behavior;
6. manager intelligence;
7. security-level institutional evidence;
8. GCC and Iraq institutional capital intelligence;
9. global/regional Investment Committee review; and
10. the Quarterly Capital Allocation & IC Brief.

The system is a research and governance tool.

It does not generate automatic investment decisions.

---

## 2. Operating Principle

The research process follows:

SEC disclosure
→ manager context
→ portfolio architecture
→ manager behavior
→ security evidence
→ regional evidence
→ evidence reconciliation
→ IC escalation
→ fundamental underwriting
→ capital decision

Institutional activity is evidence, not authorization to deploy capital.

---

## 3. Quarterly Operating Calendar

The standard quarterly review is run after the principal Form 13F filing
window has closed.

| Run Date | Portfolio Period |
|---|---|
| 20 February | Q4 of prior year |
| 20 May | Q1 |
| 20 August | Q2 |
| 20 November | Q3 |

A run may be delayed if SEC filing completeness is materially insufficient.

A historical quarter should not be silently overwritten because of later
information. Material amendments or corrections should be documented.

---

## 4. Preconditions

Before the analytical stack is run:

- PostgreSQL must be available.
- Rails application must boot successfully.
- SEC filing metadata for the relevant filing period must be imported.
- Required filings must have XML/primary-document attributes processed.
- Required manager holdings must be loaded.
- Curated manager cohort files must be valid.
- Regional institution registry must be valid.
- Material filing amendments must be reconciled.
- Known confidential-treatment or disclosure discontinuities must remain
  explicitly flagged.

The analytical stack must not conceal missing data.

Missing analytical capability must be reported as NOT_AVAILABLE,
NOT_YET_MEASURABLE or an equivalent explicit state.

---

## 5. Quarterly Execution

Run from the repository root.

Example:

    research/bin/run_quarterly_ic_review 2026 2

The runner executes the analytical reports sequentially:

01 Capital Universe
02 Capital Concentration
03 Manager Universe
04 Manager Architecture
05 Manager Behavior
06 Manager Signals
07 Security Signals
08 Regional Institutional Capital
09 Global / Regional IC Review
10 Quarterly Capital Allocation & IC Brief

Report 10 then produces the presentation outputs and the quarterly PDF.

No downstream report should be treated as validated if an upstream stage fails.

---

## 6. Required Outputs

Each quarter must create:

    research/output/YYYY-QN/

At minimum the final IC layer must contain:

- 10_capital_allocation_summary.csv
- 10_ic_answers.csv
- 10_reallocations.csv
- 10_research_queue.csv
- 10_quarterly_capital_allocation_brief.pdf

Reports 01–09 retain their respective analytical CSV outputs in the same
quarter directory.

Generated quarterly outputs are research artifacts and are not committed to
Git unless explicitly designated otherwise.

---

## 7. Validation Standard

The quarterly run is considered complete only when:

- all ten analytical reports execute successfully;
- no required Report 10 input is missing;
- Report 10 produces all required CSV outputs;
- the PDF renders successfully;
- research queues reconcile with Report 09;
- manager comparison exceptions remain visible;
- no unavailable sector/industry analysis is inferred;
- reported 13F value is not described as firm AUM;
- position value is not described as transaction value;
- regional evidence is not represented as all GCC institutional capital;
- strategic-owner behavior remains distinguishable from diversified
  portfolio-manager behavior.

---

## 8. Investment Committee Interpretation

Evidence states organize research.

They do not constitute BUY / HOLD / SELL recommendations.

Escalated securities enter one of the following research states:

- PRIORITY_RESEARCH
- PRIORITY_RISK_REVIEW
- DIVERGENCE_REVIEW
- REGIONAL_MATERIAL_REVIEW
- GLOBAL_SIGNAL_REVIEW

Capital deployment requires separate fundamental underwriting including:

- investment thesis;
- valuation;
- expected return;
- downside case;
- permanent-capital-impairment case;
- portfolio fit;
- position sizing;
- liquidity;
- governance and regulatory exposure; and
- explicit thesis-invalidating conditions.

---

## 9. Quarterly Review Questions

Every quarterly cycle must answer or explicitly defer the following:

1. Which signals persist across multiple quarters?
2. Which manager actions are economically material?
3. Where do fundamental managers disagree with broad institutional flows?
4. Where does GCC institutional behavior confirm or diverge from global evidence?
5. Which regional positions reflect strategic ownership?
6. Which signals survive data-quality and corporate-action review?
7. Which securities require fundamental valuation and downside work?
8. What subsequent performance follows each evidence state?
9. What evidence would justify capital allocation?
10. What could permanently impair capital?

An unanswered question must remain explicitly unanswered rather than inferred.

---

## 10. Record Keeping

For every quarterly cycle record:

- portfolio period;
- execution date;
- Git commit;
- database environment;
- successful/failed analytical stages;
- data-quality exceptions;
- output location;
- PDF generation status; and
- elapsed execution time.

The Git commit provides the methodology/version record.

The quarterly output directory provides the analytical record.

---

## 11. Change Control

Methodology changes must be made in source code and committed to Git.

Do not manually edit generated quarterly CSV results to alter conclusions.

Material methodology changes should be documented in the commit message and,
where appropriate, the research README.

Historical results should only be regenerated deliberately and should remain
traceable to the methodology version used.

---

## 12. Known V1 Limitations

The current system does not yet provide a validated:

- sector/industry security master;
- complete corporate-action reconciliation layer;
- subsequent-period performance layer;
- multi-quarter persistence model; or
- issuer-level fundamental underwriting engine.

These are future analytical capabilities and must not be simulated through
manual assumptions.

---

## 13. Capital-Governor Standard

The final decision framework is:

**Preserve** — protect principal before optimization.

**Investigate** — escalate evidence worthy of underwriting.

**Separate** — distinguish manager mandate and portfolio architecture.

**Demand** — require valuation, downside, sizing and liquidity evidence.

**Measure** — establish persistence and outcomes before institutionalizing
allocation rules.

The objective is not to imitate disclosed institutional portfolios.

The objective is to improve the governance of capital.
