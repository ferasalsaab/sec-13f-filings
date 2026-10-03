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
