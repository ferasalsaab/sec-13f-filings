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
