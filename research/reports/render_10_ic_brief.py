#!/usr/bin/env python3

import csv
import os
from pathlib import Path
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import (
    SimpleDocTemplate,
    Paragraph,
    Spacer,
    Table,
    TableStyle,
    PageBreak,
    KeepTogether,
)

YEAR = int(os.getenv("YEAR", "2026"))
QUARTER = int(os.getenv("QUARTER", "2"))

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "research" / "output" / f"{YEAR}-Q{QUARTER}"

SUMMARY = OUT / "10_capital_allocation_summary.csv"
ANSWERS = OUT / "10_ic_answers.csv"
REALLOCATIONS = OUT / "10_reallocations.csv"
QUEUE = OUT / "10_research_queue.csv"
PDF = OUT / "10_quarterly_capital_allocation_brief.pdf"


def read_csv(path):
    if not path.exists():
        raise FileNotFoundError(f"Missing required Report 10 output: {path}")
    with path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def text(value):
    return escape(str(value or ""))


def money(value):
    try:
        n = float(value or 0)
    except (TypeError, ValueError):
        return "-"

    if abs(n) >= 1e12:
        return f"${n / 1e12:.2f}T"
    if abs(n) >= 1e9:
        return f"${n / 1e9:.2f}B"
    if abs(n) >= 1e6:
        return f"${n / 1e6:.2f}M"
    if abs(n) >= 1e3:
        return f"${n / 1e3:.2f}K"
    return f"${n:,.0f}"


def pct(value):
    try:
        return f"{float(value):.1f}%"
    except (TypeError, ValueError):
        return "-"


summary_rows = read_csv(SUMMARY)
answers = read_csv(ANSWERS)
reallocations = read_csv(REALLOCATIONS)
queue = read_csv(QUEUE)

styles = getSampleStyleSheet()

title = ParagraphStyle(
    "ICTitle",
    parent=styles["Title"],
    fontName="Helvetica-Bold",
    fontSize=22,
    leading=27,
    alignment=TA_CENTER,
    spaceAfter=8 * mm,
)

subtitle = ParagraphStyle(
    "ICSubtitle",
    parent=styles["Normal"],
    fontName="Helvetica",
    fontSize=10,
    leading=14,
    alignment=TA_CENTER,
    textColor=colors.HexColor("#555555"),
)

h1 = ParagraphStyle(
    "ICH1",
    parent=styles["Heading1"],
    fontName="Helvetica-Bold",
    fontSize=15,
    leading=19,
    spaceBefore=5 * mm,
    spaceAfter=3 * mm,
)

h2 = ParagraphStyle(
    "ICH2",
    parent=styles["Heading2"],
    fontName="Helvetica-Bold",
    fontSize=11,
    leading=14,
    spaceBefore=3 * mm,
    spaceAfter=2 * mm,
)

body = ParagraphStyle(
    "ICBody",
    parent=styles["BodyText"],
    fontName="Helvetica",
    fontSize=8.7,
    leading=12.5,
    spaceAfter=2.2 * mm,
)

small = ParagraphStyle(
    "ICSmall",
    parent=body,
    fontSize=7.2,
    leading=9.5,
    textColor=colors.HexColor("#555555"),
)

status_style = ParagraphStyle(
    "ICStatus",
    parent=body,
    fontName="Helvetica-Bold",
    fontSize=7.8,
    leading=10,
)

callout = ParagraphStyle(
    "ICCallout",
    parent=body,
    fontName="Helvetica-Bold",
    fontSize=9,
    leading=13,
    leftIndent=4 * mm,
    rightIndent=4 * mm,
    spaceBefore=2 * mm,
    spaceAfter=3 * mm,
)

doc = SimpleDocTemplate(
    str(PDF),
    pagesize=A4,
    rightMargin=16 * mm,
    leftMargin=16 * mm,
    topMargin=17 * mm,
    bottomMargin=17 * mm,
    title=f"Quarterly Capital Allocation & IC Brief - Q{QUARTER} {YEAR}",
    author="Capital Allocation Research",
)

story = []


def footer(canvas, document):
    canvas.saveState()
    canvas.setFont("Helvetica", 7)
    canvas.setFillColor(colors.HexColor("#666666"))
    canvas.drawString(
        16 * mm,
        9 * mm,
        f"Quarterly Capital Allocation & IC Brief | Q{QUARTER} {YEAR}",
    )
    canvas.drawRightString(
        A4[0] - 16 * mm,
        9 * mm,
        f"Page {document.page}",
    )
    canvas.restoreState()


def section(name):
    story.append(Paragraph(text(name), h1))


def add_table(data, widths=None):
    converted = []
    for row in data:
        converted.append([
            cell if isinstance(cell, Paragraph)
            else Paragraph(text(cell), small)
            for cell in row
        ])

    t = Table(converted, colWidths=widths, repeatRows=1)

    t.setStyle(TableStyle([
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 4),
        ("RIGHTPADDING", (0, 0), (-1, -1), 4),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
        ("GRID", (0, 0), (-1, -1), 0.25, colors.HexColor("#DDDDDD")),
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#EDEDED")),
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
    ]))

    story.append(t)
    story.append(Spacer(1, 3 * mm))


# COVER

story.append(Spacer(1, 28 * mm))

story.append(Paragraph(
    "QUARTERLY CAPITAL ALLOCATION<br/>&amp; INVESTMENT COMMITTEE BRIEF",
    title,
))

story.append(Paragraph(
    f"Institutional Capital Intelligence | Q{QUARTER} {YEAR}",
    subtitle,
))

story.append(Spacer(1, 16 * mm))

story.append(Paragraph("Purpose", h2))

story.append(Paragraph(
    "A decision-support synthesis of observable institutional portfolio behavior, "
    "manager interpretation, regional capital activity and the resulting research "
    "and risk queue. The brief informs capital-allocation research; it does not "
    "convert institutional activity into automatic investment decisions.",
    body,
))

story.append(Spacer(1, 8 * mm))

story.append(Paragraph(
    "<b>Capital-preservation rule:</b> institutional-flow evidence can trigger "
    "investigation, but deployment requires separate fundamental underwriting, "
    "valuation, downside analysis, sizing, liquidity and thesis-invalidating conditions.",
    callout,
))

story.append(PageBreak())


# 1 EXECUTIVE VIEW

section("1. Executive Capital View")

metric_table = [["Metric", "Quarterly observation"]]

for row in summary_rows:
    metric_table.append([
        row["metric"].replace("_", " ").title(),
        row["value"],
    ])

add_table(metric_table, widths=[85 * mm, 85 * mm])

story.append(Paragraph(
    "<b>Interpretation:</b> reported 13F value represents observable reportable "
    "securities and should not be interpreted as firm AUM. Research readiness, "
    "interpretability and capital importance are separate dimensions.",
    body,
))


# 2 EVIDENCE FRAMEWORK

section("2. Evidence Framework")

definitions = [
    ["Term", "Meaning"],
    [
        "Reported 13F value",
        "Observable reportable securities disclosed through Form 13F; not total firm AUM.",
    ],
    [
        "High interpretability",
        "Manager disclosure whose 13F behavior more plausibly reflects underlying investment decisions.",
    ],
    [
        "Fundamental evidence",
        "Behavior observed within the curated fundamental-manager research cohort.",
    ],
    [
        "Regional evidence",
        "Behavior of the identified GCC/Iraq analytical cohort; not all regional institutional capital.",
    ],
    [
        "Material regional decision",
        "A regional disclosed action meeting the portfolio-weight materiality rule for the quarter.",
    ],
    [
        "Divergence",
        "Directional disagreement between evidence groups; not proof that either group is correct.",
    ],
    [
        "Escalation",
        "A research-priority designation, not an investment recommendation.",
    ],
]

add_table(definitions, widths=[42 * mm, 128 * mm])


# 3 CAPITAL REALLOCATION

section("3. Capital Reallocation")

story.append(Paragraph(
    "The tables below show disclosed position changes. Quarter-end position values "
    "are not transaction proceeds and should not be interpreted as the amount of "
    "capital purchased or sold.",
    body,
))

global_rows = [
    r for r in reallocations
    if r["scope"] == "GLOBAL_INTERPRETABLE"
]

regional_rows = [
    r for r in reallocations
    if r["scope"] == "REGIONAL"
]

for action in ["NEW", "ADD", "REDUCE", "EXIT"]:
    rows = [
        r for r in global_rows
        if r["action"] == action
    ][:5]

    if not rows:
        continue

    story.append(Paragraph(
        f"Global interpretable - {action}",
        h2,
    ))

    data = [["Manager", "Security", "Q1", "Q2"]]

    for row in rows:
        data.append([
            row["manager"],
            row["issuer"],
            money(row["q1_value"]),
            money(row["q2_value"]),
        ])

    add_table(
        data,
        widths=[50 * mm, 65 * mm, 27 * mm, 27 * mm],
    )


story.append(Paragraph(
    "Largest material regional movements",
    h2,
))

regional_sorted = sorted(
    regional_rows,
    key=lambda r: float(r["portfolio_weight_pct"] or 0),
    reverse=True,
)[:15]

data = [[
    "Institution",
    "Action",
    "Security",
    "Q2 weight",
    "Q1",
    "Q2",
]]

for row in regional_sorted:
    data.append([
        row["manager"],
        row["action"],
        row["issuer"],
        pct(row["portfolio_weight_pct"]),
        money(row["q1_value"]),
        money(row["q2_value"]),
    ])

add_table(
    data,
    widths=[
        39 * mm,
        17 * mm,
        50 * mm,
        20 * mm,
        22 * mm,
        22 * mm,
    ],
)


# 4 INDUSTRY / SECTOR

section("4. Industry & Sector Allocation")

story.append(Paragraph(
    "<b>STATUS: NOT AVAILABLE</b>",
    status_style,
))

story.append(Paragraph(
    "The current quarterly security evidence does not contain a validated "
    "sector/industry taxonomy. No sector-rotation or industry-flow conclusion is "
    "generated. This section should populate only after a validated security master "
    "is available upstream.",
    body,
))


# 5 RESEARCH QUEUE

section("5. Research & Risk Queue")

bucket_order = [
    "PRIORITY_RESEARCH",
    "PRIORITY_RISK_REVIEW",
    "DIVERGENCE_REVIEW",
    "REGIONAL_MATERIAL_REVIEW",
    "GLOBAL_SIGNAL_REVIEW",
]

for bucket in bucket_order:
    rows = [
        r for r in queue
        if r["escalation_bucket"] == bucket
    ]

    if not rows:
        continue

    story.append(Paragraph(
        f"{bucket.replace('_', ' ')} - {len(rows)}",
        h2,
    ))

    data = [[
        "Security",
        "Evidence state",
        "Fund.",
        "HI",
        "Regional",
        "Material",
    ]]

    for row in rows[:10]:
        data.append([
            row["issuer"],
            row["evidence_state"],
            row["fundamental_net"],
            row["high_interpretability_net"],
            row["regional_net"],
            row["regional_material_decisions"],
        ])

    add_table(
        data,
        widths=[
            42 * mm,
            72 * mm,
            14 * mm,
            14 * mm,
            16 * mm,
            16 * mm,
        ],
    )

story.append(Paragraph(
    "Only the highest-priority observations are shown where a queue is long. "
    "The complete research queue remains available in the Report 10 CSV output.",
    small,
))


# 6 IC QUESTIONS

story.append(PageBreak())

section("6. Ten Investment Committee Questions")

for row in answers:
    block = [
        Paragraph(
            f"Q{text(row['question_number'])}. {text(row['question'])}",
            h2,
        ),
        Paragraph(
            f"<b>Status:</b> {text(row['status'])}",
            status_style,
        ),
        Paragraph(
            f"<b>Answer:</b> {text(row['answer'])}",
            body,
        ),
        Paragraph(
            f"<b>Decision implication:</b> {text(row['decision_implication'])}",
            body,
        ),
        Paragraph(
            f"<b>Evidence:</b> {text(row['evidence'])}",
            small,
        ),
        Spacer(1, 2 * mm),
    ]

    story.append(KeepTogether(block))


# 7 CAPITAL GOVERNOR

section("7. $10B Capital-Governor View")

governor_rules = [
    (
        "Preserve",
        "Do not deploy capital solely from quarterly institutional-flow evidence.",
    ),
    (
        "Investigate",
        "Prioritize escalated securities according to evidence strength and materiality.",
    ),
    (
        "Separate",
        "Distinguish strategic-owner behavior from diversified portfolio-manager behavior.",
    ),
    (
        "Demand",
        "Require valuation, expected return, downside, sizing, liquidity, portfolio fit and thesis-invalidating evidence.",
    ),
    (
        "Measure",
        "Establish persistence and subsequent outcomes before promoting recurring signals into allocation rules.",
    ),
]

for heading, statement in governor_rules:
    story.append(Paragraph(
        f"<b>{heading}:</b> {statement}",
        body,
    ))


# 8 NEXT QUARTER

section("8. Next-Quarter Decision Tests")

tests = [
    "Test whether current accumulation and distribution evidence persists.",
    "Recalculate materiality using the next quarterly portfolio state.",
    "Reassess global/regional divergences for convergence, persistence or reversal.",
    "Track whether current research-priority securities remain escalated.",
    "Begin subsequent-period performance measurement when validated market data is available.",
    "Add sector and industry analysis only after validated security classification exists.",
]

for item in tests:
    story.append(Paragraph(
        f"- {text(item)}",
        body,
    ))


# 9 LIMITATIONS

section("9. Methodology & Limitations")

limitations = [
    "13F filings are delayed disclosures and do not provide real-time portfolio positioning.",
    "13F disclosures cover reportable long U.S.-listed securities and do not represent complete economic exposure.",
    "Reported 13F value is not equivalent to firm AUM.",
    "Quarter-end position value is not equivalent to capital transacted during the quarter.",
    "Options, confidential treatment, amendments, corporate actions and security-identity changes can affect interpretation.",
    "Strategic owners, passive managers, quantitative managers, market makers and fundamental managers should not be interpreted identically.",
    "The regional cohort is an analytical sample and is not a complete representation of GCC or Iraq institutional capital.",
    "Evidence states and escalation buckets organize research; they do not constitute buy, hold or sell recommendations.",
]

for item in limitations:
    story.append(Paragraph(
        f"- {text(item)}",
        body,
    ))

story.append(Spacer(1, 4 * mm))

story.append(Paragraph(
    "<b>Audit outputs:</b> "
    "10_capital_allocation_summary.csv; "
    "10_ic_answers.csv; "
    "10_reallocations.csv; "
    "10_research_queue.csv.",
    small,
))

doc.build(
    story,
    onFirstPage=footer,
    onLaterPages=footer,
)

print(f"Created: {PDF}")
