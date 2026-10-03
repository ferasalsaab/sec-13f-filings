# Institutional 13F Research

A repeatable quarterly research framework for analysing institutional capital allocation using SEC Form 13F data.

## Research Cycle

Run after the quarterly 13F filing window has substantially closed:

- Q4 portfolios: February
- Q1 portfolios: May
- Q2 portfolios: August
- Q3 portfolios: November

## Standard Reports

1. Capital Universe
2. Capital Concentration
3. Manager Universe
4. Manager Architecture
5. Manager Behavior
6. Manager Signals
7. Security Signals

## Report 01 — Capital Universe

Research question:

> What is the size and distribution of the observable U.S. 13F institutional capital universe?

Run:

    bundle exec rails runner research/reports/01_capital_universe.rb YEAR QUARTER

Example:

    bundle exec rails runner research/reports/01_capital_universe.rb 2026 2

Outputs are written to:

    research/output/YEAR-QX/

Reported 13F value should not be interpreted as total firm AUM.

## Report 02 — Capital Concentration

Research question:

> How concentrated is observable institutional capital, and how many managers account for economically meaningful shares of it?

Run:

    bundle exec rails runner research/reports/02_capital_concentration.rb YEAR QUARTER

Example:

    bundle exec rails runner research/reports/02_capital_concentration.rb 2026 2

Measures include:

- capital controlled by top manager percentiles
- managers required for 25%, 50%, 75%, 90%, 95% and 99% capital coverage
- Top-N manager concentration
- capital-distribution HHI
- effective manager count

The effective manager count represents the number of equally sized managers that would produce the observed HHI. It is a concentration statistic, not a literal count of independent institutions.

Concentration is measured at the 13F reporting-entity level. Related reporting entities may belong to the same parent institution.

## Report 03 — Manager Universe

Research question:

> Who are the institutions controlling observable capital, where do they rank, and which managers belong in the research universe?

Run:

    bundle exec rails runner research/reports/03_manager_universe.rb YEAR QUARTER

Example:

    bundle exec rails runner research/reports/03_manager_universe.rb 2026 2

Outputs:

- full manager universe
- Core 500
- Top 100
- Top 25

Research-universe hierarchy:

- Extreme Capital Core: Top 25
- Major Capital: ranks 26–100
- Core Capital: ranks 101–500
- Institutional: >= $10B outside Top 500
- Extended: >= $1B
- Full: remaining managers

Capital importance must not be interpreted as investment signal quality.

Holdings availability is explicitly distinguished from portfolio structure. A manager whose detailed holdings have not been materialised is NOT_LOADED rather than a zero-position portfolio.

## Report 04 — Manager Architecture

Research question:

> How is each manager's observable 13F portfolio constructed?

Run:

    bundle exec rails runner research/reports/04_manager_architecture.rb YEAR QUARTER

Example:

    bundle exec rails runner research/reports/04_manager_architecture.rb 2026 2

Report 04 requires detailed holdings to have been materialised locally.

Measures include:

- reported 13F value
- long non-option value
- long non-option / reported value
- non-long reported value
- position count
- Top 1 / Top 5 / Top 10 / Top 20 concentration
- portfolio HHI
- effective positions
- largest observable position

Architecture is descriptive. It does not by itself establish investment conviction, manager skill or signal quality.

Long non-option holdings are used as the primary architecture denominator to reduce distortion from options and other reported exposures.

## Report 08 — Regional Institutional Capital

`08_regional_institutional_capital.rb`

Builds a GCC + Iraq institutional-capital intelligence layer.

The report separates:

- regional 13F portfolio managers with observable holdings;
- other SEC-visible strategic ownership;
- important regional institutions without a qualifying 13F portfolio;
- unresolved institutional-capital universes requiring further discovery.

Core outputs include country-level observable 13F capital, portfolio architecture,
QoQ behavior using security units rather than market values, and cross-institution
security alignment with decision materiality.

Security identity uses CUSIP as the primary identifier, with option type and
share/principal-amount type retained where economically relevant. Descriptive
class-title changes are not treated as security changes.

Important limitations:

- 13F value is not total institution AUM.
- QoQ reported-value change is not investment performance.
- 13F captures only the observable reportable portfolio.
- Strategic holdings and diversified portfolios should not be interpreted identically.
- Regional security alignment measures evidence within the identified reporting cohort,
  not the entire GCC institutional-capital universe.
- Combined security weight is the sum of participating managers' individual portfolio
  weights and is not a regional portfolio weight.
- 13D/13G and other SEC disclosures remain analytically separate from 13F portfolio data.

## Report 09 — Global & Regional Institutional Capital Review

`09_global_regional_ic_review.rb`

Synthesizes the research stack into a quarterly investment-committee research view.

The report combines:

- global reported 13F capital structure and concentration;
- manager intelligence and disclosure quality;
- quarterly manager behavior;
- global security-level institutional evidence;
- GCC and Iraq institutional-capital intelligence;
- global versus regional security alignment;
- evidence escalation for further research;
- capital-allocation and downside-review questions.

Evidence escalation is deliberately separate from evidence classification.

Material regional/global divergences are escalated for review, while non-material
differences remain preserved in the underlying analytical output without automatically
entering the investment-committee queue.

Escalation categories are research workflow states, not investment recommendations.

Important limitations:

- 13F reported value is not institution AUM.
- Reported portfolio-value changes are not investment performance.
- 13F disclosures are delayed and incomplete representations of economic exposure.
- Manager mandate and portfolio architecture must precede conviction inference.
- Regional evidence represents the identified reporting cohort, not the entire GCC or Iraqi institutional-capital universe.
- Strategic ownership must be distinguished from diversified portfolio-manager behavior.
- Cross-market agreement or divergence is evidence for further research, not a buy or sell signal.
- Performance and persistence require subsequent-quarter observation and are not inferred from a single reporting period.
