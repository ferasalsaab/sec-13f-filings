require "csv"
require "fileutils"
require "set"

YEAR = ENV.fetch("YEAR", "2026").to_i
QUARTER = ENV.fetch("QUARTER", "2").to_i

OUTPUT_DIR = Rails.root.join("research", "output", "#{YEAR}-Q#{QUARTER}")

def read_csv(name)
  path = OUTPUT_DIR.join(name)
  raise "Missing required quarterly output: #{path}" unless File.exist?(path)

  CSV.read(path, headers: true)
end

def f(value)
  value.to_f
end

def i(value)
  value.to_i
end

def money(value)
  number = value.to_f
  n = number.abs

  formatted =
    if n >= 1_000_000_000_000
      format("$%.2fT", n / 1_000_000_000_000.0)
    elsif n >= 1_000_000_000
      format("$%.2fB", n / 1_000_000_000.0)
    elsif n >= 1_000_000
      format("$%.2fM", n / 1_000_000.0)
    elsif n >= 1_000
      format("$%.2fK", n / 1_000.0)
    else
      format("$%.2f", n)
    end

  number.negative? ? "-#{formatted}" : formatted
end

def pct(value)
  format("%.1f%%", value.to_f)
end

def answer(status, text, evidence = nil)
  {
    status: status,
    answer: text,
    evidence: evidence
  }
end

summary_01 = read_csv("01_capital_universe_summary.csv").first
manager_behavior = read_csv("05_manager_behavior_summary.csv")
manager_signals = read_csv("06_manager_signals.csv")
security_signals = read_csv("07_security_signals.csv")
regional_capital = read_csv("08_regional_institutional_capital.csv")
regional_behavior = read_csv("08_regional_behavior.csv")
alignment = read_csv("09_global_regional_alignment.csv")
watchlist = read_csv("09_ic_watchlist.csv")

# -------------------------------------------------------------------
# QUARTERLY STATE
# -------------------------------------------------------------------

global_capital = f(summary_01["total_reported_13f_value"])
global_managers = i(summary_01["managers"])

regional_q2 = regional_capital.sum { |r| f(r["q2_reported_value"]) }

comparable = manager_behavior.select {
  |r| r["comparison_status"] == "COMPARABLE"
}

quality_exceptions = manager_behavior.select {
  |r|
    r["comparison_status"] != "COMPARABLE" ||
    r["data_quality"] != "OK"
}

ready_managers = manager_signals.select {
  |r| r["research_readiness"] == "READY"
}

high_interpretability = manager_signals.select {
  |r| r["interpretability"] == "HIGH"
}

# -------------------------------------------------------------------
# GLOBAL INTERPRETABLE CAPITAL REALLOCATION
# -------------------------------------------------------------------

behavior_detail = read_csv("05_manager_behavior_detail.csv")

usable_manager_names =
  manager_signals.select {
    |r|
      %w[HIGH MEDIUM].include?(r["interpretability"]) &&
      r["research_readiness"] == "READY"
  }.map { |r| r["manager"] }.to_set

comparable_manager_names =
  manager_behavior.select {
    |r|
      r["comparison_status"] == "COMPARABLE" &&
      r["data_quality"] == "OK"
  }.map { |r| r["manager"] }.to_set

eligible_global_managers =
  usable_manager_names & comparable_manager_names

global_interpretable_actions =
  behavior_detail.select {
    |r|
      eligible_global_managers.include?(r["manager"]) &&
      %w[NEW ADD REDUCE EXIT].include?(r["action"]) &&
      r["data_quality"] == "OK"
  }

global_moves_by_action = {}

%w[NEW ADD REDUCE EXIT].each do |action|
  rows = global_interpretable_actions.select { |r| r["action"] == action }

  global_moves_by_action[action] =
    rows.sort_by {
      |r|
        economic_value =
          case action
          when "EXIT"
            f(r["q1_value"])
          when "REDUCE"
            [f(r["q1_value"]), f(r["q2_value"])].max
          else
            f(r["q2_value"])
          end

        -economic_value
    }.first(10)
end

# -------------------------------------------------------------------
# CAPITAL REALLOCATION
# -------------------------------------------------------------------

behavior_actions = []

regional_behavior.each do |r|
  next unless %w[NEW ADD REDUCE EXIT].include?(r["action"])

  behavior_actions << {
    source: "REGIONAL",
    institution: r["institution"],
    issuer: r["issuer_name"],
    cusip: r["cusip"],
    action: r["action"],
    q1_value: f(r["q1_value"]),
    q2_value: f(r["q2_value"]),
    q2_weight: f(r["q2_position_weight_pct"])
  }
end

largest_regional_moves =
  behavior_actions.sort_by {
    |r| [-r[:q2_weight].abs, -[r[:q1_value], r[:q2_value]].max]
  }.first(15)

# -------------------------------------------------------------------
# SECURITY EVIDENCE
# -------------------------------------------------------------------

fundamental_accumulation =
  security_signals.select { |r| i(r["fundamental_net"]) > 0 }
                  .sort_by {
                    |r|
                      [
                        -i(r["fundamental_net"]),
                        -i(r["high_interpretability_net"]),
                        -i(r["clean_net"]),
                        -i(r["manager_breadth"])
                      ]
                  }

fundamental_distribution =
  security_signals.select { |r| i(r["fundamental_net"]) < 0 }
                  .sort_by {
                    |r|
                      [
                        i(r["fundamental_net"]),
                        i(r["high_interpretability_net"]),
                        i(r["clean_net"]),
                        -i(r["manager_breadth"])
                      ]
                  }

# -------------------------------------------------------------------
# IC ESCALATION
# -------------------------------------------------------------------

priority_research =
  watchlist.select { |r| r["escalation_bucket"] == "PRIORITY_RESEARCH" }

priority_risk =
  watchlist.select { |r| r["escalation_bucket"] == "PRIORITY_RISK_REVIEW" }

divergence =
  watchlist.select { |r| r["escalation_bucket"] == "DIVERGENCE_REVIEW" }

regional_material =
  watchlist.select { |r| r["escalation_bucket"] == "REGIONAL_MATERIAL_REVIEW" }

global_signal =
  watchlist.select { |r| r["escalation_bucket"] == "GLOBAL_SIGNAL_REVIEW" }

# -------------------------------------------------------------------
# INDUSTRY / SECTOR AVAILABILITY
# -------------------------------------------------------------------

security_columns = security_signals.headers.map(&:downcase)

industry_available =
  security_columns.any? { |h|
    %w[sector industry gics_sector gics_industry sic naics].include?(h)
  }

# -------------------------------------------------------------------
# INVESTMENT COMMITTEE QUESTIONS & ANSWERS
# -------------------------------------------------------------------

answers = []

# Q1 — Persistence
answers << {
  question: "Which signals persist across multiple quarters rather than appearing once?",
  status: "NOT_YET_MEASURABLE",
  answer:
    "The available quarterly evidence does not yet contain sufficient signal history to " \
    "distinguish persistent institutional behavior from one-quarter activity.",
  implication:
    "Treat current signals as research evidence, not persistent allocation signals.",
  evidence:
    "Current quarterly review; subsequent quarterly observations required"
}

# Q2 — Economic materiality
material_regional =
  alignment.select { |r| i(r["regional_material_decisions"]) > 0 }

material_regional_decisions =
  material_regional.sum { |r| i(r["regional_material_decisions"]) }

largest_material_regional =
  material_regional.sort_by {
    |r| [-i(r["regional_material_decisions"]), -f(r["regional_q2_weight_sum_pct"])]
  }.first(5)

q2_examples =
  largest_material_regional.map {
    |r|
      "#{r["issuer_name"] || r["issuer"]} " \
      "(#{i(r["regional_material_decisions"])} material decision(s), " \
      "regional weight sum #{pct(r["regional_q2_weight_sum_pct"])})"
  }.join("; ")

answers << {
  question: "Which manager actions are economically material relative to their portfolio?",
  status: material_regional.any? ? "ANSWERED" : "INSUFFICIENT_EVIDENCE",
  answer:
    "#{material_regional.length} securities contain at least one economically material " \
    "regional decision, representing #{material_regional_decisions} material decisions. " \
    "#{q2_examples.empty? ? "" : "Largest observable examples: #{q2_examples}."}",
  implication:
    "Materiality determines which disclosed movements deserve deeper research; manager mandate " \
    "and portfolio architecture must still be considered before inferring conviction.",
  evidence:
    "09_global_regional_alignment.csv"
}

# Q3 — Fundamental vs broad institutional divergence
broad_buy_fund_sell =
  security_signals.select {
    |r| r["evidence_label"] == "DIVERGENT_BROAD_BUY_FUND_SELL"
  }

broad_sell_fund_buy =
  security_signals.select {
    |r| r["evidence_label"] == "DIVERGENT_BROAD_SELL_FUND_BUY"
  }

fundamental_flow_divergences =
  broad_buy_fund_sell + broad_sell_fund_buy

strongest_fundamental_divergences =
  fundamental_flow_divergences.sort_by {
    |r|
      [
        -i(r["fundamental_net"]).abs,
        -i(r["high_interpretability_net"]).abs,
        -i(r["manager_breadth"])
      ]
  }.first(5)

q3_examples =
  strongest_fundamental_divergences.map {
    |r|
      "#{r["issuer"]} (Fund #{i(r["fundamental_net"])}, broad net #{i(r["clean_net"])})"
  }.join("; ")

answers << {
  question: "Where do high-interpretability fundamental managers disagree with broad institutional flows?",
  status: fundamental_flow_divergences.any? ? "ANSWERED" : "INSUFFICIENT_EVIDENCE",
  answer:
    "#{fundamental_flow_divergences.length} securities show directional disagreement between " \
    "broad institutional breadth and fundamental-manager evidence: " \
    "#{broad_buy_fund_sell.length} broad-buy/fundamental-sell and " \
    "#{broad_sell_fund_buy.length} broad-sell/fundamental-buy. " \
    "#{q3_examples.empty? ? "" : "Strong examples include #{q3_examples}."}",
  implication:
    "Divergence is a research question, not evidence that either cohort is correct. Investigate " \
    "mandate, valuation, time horizon and portfolio-construction differences.",
  evidence:
    "07_security_signals.csv"
}

# Q4 — Global vs regional alignment
aligned =
  alignment.select {
    |r|
      %w[
        GLOBAL_AND_REGIONAL_ACCUMULATION
        GLOBAL_AND_REGIONAL_DISTRIBUTION
      ].include?(r["evidence_state"])
  }

cross_market_divergence =
  alignment.select {
    |r|
      %w[
        GLOBAL_DISTRIBUTION_REGIONAL_ACCUMULATION
        GLOBAL_ACCUMULATION_REGIONAL_DISTRIBUTION
      ].include?(r["evidence_state"])
  }

material_cross_market_divergence =
  cross_market_divergence.select {
    |r| i(r["regional_material_decisions"]) > 0
  }

material_alignment =
  aligned.select {
    |r| i(r["regional_material_decisions"]) > 0
  }

q4_divergence_examples =
  material_cross_market_divergence.sort_by {
    |r|
      [
        -i(r["regional_material_decisions"]),
        -f(r["regional_q2_weight_sum_pct"])
      ]
  }.first(5).map {
    |r|
      "#{r["issuer_name"] || r["issuer"]} (#{r["evidence_state"]})"
  }.join("; ")

answers << {
  question: "Where does GCC institutional behavior confirm or diverge from global institutional evidence?",
  status: "ANSWERED",
  answer:
    "#{aligned.length} securities show aligned global/regional direction, of which " \
    "#{material_alignment.length} contain material regional decisions. " \
    "#{cross_market_divergence.length} show direct global/regional directional divergence, " \
    "of which #{material_cross_market_divergence.length} contain material regional decisions. " \
    "#{q4_divergence_examples.empty? ? "" : "Material divergence examples include #{q4_divergence_examples}."}",
  implication:
    "Prioritize material divergences for mandate-aware investigation; do not interpret the regional " \
    "cohort as representative of all GCC institutional capital.",
  evidence:
    "09_global_regional_alignment.csv"
}

# Q5 — Strategic ownership
strategic_institutions =
  regional_capital.select {
    |r|
      %w[
        STRATEGIC_DOMINATED
        SINGLE_POSITION_STRATEGIC
      ].include?(r["architecture_class"])
  }

strategic_examples =
  strategic_institutions.map {
    |r|
      "#{r["institution"]} (#{r["architecture_class"]}, " \
      "Top1 #{pct(r["q2_top1_pct"])})"
  }.join("; ")

answers << {
  question: "Which regional positions reflect strategic ownership rather than portfolio-manager conviction?",
  status: strategic_institutions.any? ? "ANSWERED" : "INSUFFICIENT_EVIDENCE",
  answer:
    "#{strategic_institutions.length} regional reporting institutions have portfolio architecture " \
    "classified as strategic-dominated or single-position strategic. " \
    "#{strategic_examples.empty? ? "" : "They are #{strategic_examples}."}",
  implication:
    "Movements from strategic-owner portfolios must be analyzed separately from diversified " \
    "portfolio-manager security selection.",
  evidence:
    "08_regional_institutional_capital.csv"
}

# Q6 — Data quality / corporate actions
quality_exception_text =
  quality_exceptions.map {
    |r|
      "#{r["manager"]} (comparison=#{r["comparison_status"]}, " \
      "data_quality=#{r["data_quality"]}, reason=#{r["status_reason"]})"
  }.join("; ")

quality_exception_sentence =
  if quality_exception_text.empty?
    ""
  else
    " Current exceptions: #{quality_exception_text}."
  end

answers << {
  question: "Which signals survive corporate-action and disclosure-quality review?",
  status: quality_exceptions.empty? ? "PARTIALLY_ANSWERED" : "CAUTION_REQUIRED",
  answer:
    "#{quality_exceptions.length} manager histories carry comparison or disclosure-quality " \
    "exceptions.#{quality_exception_sentence} Security identity controls reduce false signals, " \
    "but a complete corporate-action security master is not yet available.",
  implication:
    "Treat clean ADD/REDUCE evidence as more interpretable than unresolved NEW/EXIT identity changes, " \
    "and quarantine disclosure discontinuities from strong conviction inference.",
  evidence:
    "05_manager_behavior_summary.csv"
}

# Q7 — Fundamental research queue
fundamental_research_queue =
  priority_research +
  priority_risk +
  divergence +
  regional_material +
  global_signal

q7_examples =
  fundamental_research_queue.first(10).map {
    |r|
      "#{r["issuer"]} (#{r["escalation_bucket"]})"
  }.join("; ")

answers << {
  question: "Which escalated securities warrant fundamental valuation and downside analysis?",
  status: fundamental_research_queue.any? ? "ANSWERED" : "INSUFFICIENT_EVIDENCE",
  answer:
    "#{fundamental_research_queue.length} security observations are escalated beyond monitoring: " \
    "#{priority_research.length} priority research, #{priority_risk.length} priority risk review, " \
    "#{divergence.length} material divergence review, #{regional_material.length} regional material review, " \
    "and #{global_signal.length} global signal review. " \
    "#{q7_examples.empty? ? "" : "The highest-priority queue begins with #{q7_examples}."}",
  implication:
    "Escalation determines research order. It does not establish expected return or authorize capital deployment.",
  evidence:
    "09_ic_watchlist.csv"
}

# Q8 — Forward performance
answers << {
  question: "What subsequent 1Q, 2Q and 4Q performance follows each evidence state?",
  status: "NOT_YET_MEASURABLE",
  answer:
    "Forward 1Q, 2Q and 4Q performance is not yet available from the current quarterly research history, " \
    "and the research stack does not yet contain a validated benchmark/performance layer.",
  implication:
    "Do not claim predictive value for any evidence state until subsequent outcomes can be measured.",
  evidence:
    "Future quarterly observations and market-performance enrichment required"
}

# Q9 — Deployment threshold
answers << {
  question: "What evidence would justify allocating capital rather than continuing observation?",
  status: "GOVERNANCE_RULE",
  answer:
    "Institutional-flow evidence alone does not justify deployment. Capital allocation requires a " \
    "fundamental investment thesis, valuation and expected return, downside scenario, portfolio fit, " \
    "position-sizing logic, liquidity assessment, and explicit thesis-invalidating conditions. " \
    "Persistent institutional evidence can strengthen that case but cannot replace it.",
  implication:
    "The current system generates research priorities. A separate underwriting process must authorize deployment.",
  evidence:
    "Capital-governance methodology"
}

# Q10 — Permanent impairment
answers << {
  question: "What could permanently impair capital if the thesis is wrong?",
  status: "REQUIRES_FUNDAMENTAL_RESEARCH",
  answer:
    "13F behavior cannot determine issuer-specific permanent-capital-impairment risk. Each escalated security " \
    "requires analysis of leverage and liquidity, business-model durability, competitive position, valuation, " \
    "governance, dilution, regulatory exposure and adverse operating scenarios.",
  implication:
    "No security should move from research to allocation without an explicit permanent-loss case and defined risk limits.",
  evidence:
    "Issuer-level fundamental underwriting required"
}

# -------------------------------------------------------------------
# TERMINAL BRIEF
# -------------------------------------------------------------------

puts
puts "REPORT 10 — QUARTERLY CAPITAL ALLOCATION & IC BRIEF"
puts "=" * 68
puts "Portfolio period: Q#{QUARTER} #{YEAR}"
puts

puts "1. EXECUTIVE ALLOCATION VIEW"
puts "----------------------------"
puts "Global observable 13F capital: #{money(global_capital)} across #{global_managers} reporting entities"
puts "Regional observable 13F capital: #{money(regional_q2)}"
puts "Research-ready managers: #{ready_managers.length}"
puts "HIGH-interpretability managers: #{high_interpretability.length}"
puts "Comparable manager histories: #{comparable.length}"
puts "Priority research: #{priority_research.length}"
puts "Priority risk review: #{priority_risk.length}"
puts "Material divergence review: #{divergence.length}"
puts "Regional material review: #{regional_material.length}"
puts "Global signal review: #{global_signal.length}"
puts

puts "2. CAPITAL REALLOCATION"
puts "-----------------------"

puts "Global interpretable manager movements:"
%w[NEW ADD REDUCE EXIT].each do |action|
  puts
  puts "#{action}:"
  global_moves_by_action[action].first(5).each do |r|
    reference_value =
      action == "EXIT" ? f(r["q1_value"]) : f(r["q2_value"])

    puts "  #{r["manager"]} | #{r["issuer_name"]} | " \
         "Q1 #{money(r["q1_value"])} | Q2 #{money(r["q2_value"])} | " \
         "reference #{money(reference_value)}"
  end
end

puts
puts "Largest material regional movements:"
largest_regional_moves.each do |r|
  puts "#{r[:institution]} | #{r[:action]} | #{r[:issuer]} | " \
       "Q2 weight #{pct(r[:q2_weight])} | Q1 #{money(r[:q1_value])} | Q2 #{money(r[:q2_value])}"
end
puts

puts "3. INDUSTRY & SECTOR FLOWS"
puts "--------------------------"
if industry_available
  puts "Sector/industry classification detected in quarterly security evidence."
  puts "Industry aggregation should be generated from the available classification fields."
else
  puts "STATUS: NOT_AVAILABLE"
  puts "The quarterly security evidence contains no validated sector/industry taxonomy."
  puts "No industry-flow conclusion is generated."
end
puts

puts "4. CAPITAL RESEARCH PRIORITIES"
puts "------------------------------"
[
  ["PRIORITY_RESEARCH", priority_research],
  ["PRIORITY_RISK_REVIEW", priority_risk],
  ["DIVERGENCE_REVIEW", divergence],
  ["REGIONAL_MATERIAL_REVIEW", regional_material],
  ["GLOBAL_SIGNAL_REVIEW", global_signal]
].each do |label, rows|
  puts "#{label}: #{rows.length}"
  rows.first(5).each do |r|
    issuer = r["issuer"] || r["issuer_name"]
    puts "  #{issuer} | #{r["evidence_state"]}"
  end
end
puts

puts "5. CURRENT CAPITAL POSTURE"
puts "--------------------------"
puts "RESEARCH: #{priority_research.length}"
puts "RISK REVIEW: #{priority_risk.length}"
puts "DIVERGENCE: #{divergence.length}"
puts "REGIONAL REVIEW: #{regional_material.length}"
puts "GLOBAL SIGNAL REVIEW: #{global_signal.length}"
puts "NO AUTOMATIC CAPITAL DEPLOYMENT: institutional-flow evidence is an input, not an investment decision."
puts

puts "6. TEN INVESTMENT COMMITTEE QUESTIONS & ANSWERS"
puts "-----------------------------------------------"
answers.each_with_index do |a, idx|
  puts
  puts "Q#{idx + 1}. #{a[:question]}"
  puts "STATUS: #{a[:status]}"
  puts "ANSWER: #{a[:answer]}"
  puts "DECISION IMPLICATION: #{a[:implication]}"
  puts "EVIDENCE: #{a[:evidence]}" if a[:evidence]
end
puts

puts "7. $10B CAPITAL-GOVERNOR VIEW"
puts "-----------------------------"
puts "Preserve: do not deploy capital solely from quarterly institutional-flow evidence."
puts "Investigate: prioritize escalated securities according to evidence strength and materiality."
puts "Separate: strategic-owner behavior from diversified portfolio-manager behavior."
puts "Demand: valuation, expected return, downside, sizing, liquidity, portfolio fit and thesis-invalidating evidence."
puts "Measure: persistence and subsequent outcomes before promoting recurring signals into allocation rules."
puts

puts "8. NEXT-QUARTER TESTS"
puts "---------------------"
puts "• Test whether current accumulation and distribution evidence persists."
puts "• Recalculate materiality using the next quarterly portfolio state."
puts "• Reassess global/regional divergences for convergence, persistence or reversal."
puts "• Track whether current research-priority securities remain escalated."
puts "• Begin subsequent-period performance measurement when market data is available."
puts "• Add sector/industry analysis only after validated security classification exists."
puts

# -------------------------------------------------------------------
# OUTPUT FILES
# -------------------------------------------------------------------

FileUtils.mkdir_p(OUTPUT_DIR)

answers_path = OUTPUT_DIR.join("10_ic_answers.csv")
CSV.open(answers_path, "w") do |csv|
  csv << %w[question_number question status answer decision_implication evidence]
  answers.each_with_index do |a, idx|
    csv << [
      idx + 1,
      a[:question],
      a[:status],
      a[:answer],
      a[:implication],
      a[:evidence]
    ]
  end
end

brief_path = OUTPUT_DIR.join("10_capital_allocation_summary.csv")
CSV.open(brief_path, "w") do |csv|
  csv << %w[metric value]
  csv << ["portfolio_period", "#{YEAR}-Q#{QUARTER}"]
  csv << ["global_reporting_entities", global_managers]
  csv << ["global_reported_13f_value", global_capital]
  csv << ["regional_reported_13f_value", regional_q2]
  csv << ["research_ready_managers", ready_managers.length]
  csv << ["high_interpretability_managers", high_interpretability.length]
  csv << ["priority_research", priority_research.length]
  csv << ["priority_risk_review", priority_risk.length]
  csv << ["divergence_review", divergence.length]
  csv << ["regional_material_review", regional_material.length]
  csv << ["global_signal_review", global_signal.length]
  csv << ["industry_analysis_available", industry_available]
end

# -------------------------------------------------------------------
# REPORT 10 PRESENTATION-LAYER REALLOCATION OUTPUT
# -------------------------------------------------------------------

research_queue_path = OUTPUT_DIR.join("10_research_queue.csv")

CSV.open(research_queue_path, "w") do |csv|
  csv << [
    "research_priority",
    "escalation_bucket",
    "cusip",
    "issuer",
    "evidence_state",
    "global_evidence_label",
    "fundamental_net",
    "high_interpretability_net",
    "regional_net",
    "regional_material_decisions",
    "regional_q2_weight_sum_pct"
  ]

  watchlist.each do |r|
    csv << [
      r["research_priority"],
      r["escalation_bucket"],
      r["cusip"],
      r["issuer"],
      r["evidence_state"],
      r["global_evidence_label"],
      r["fundamental_net"],
      r["high_interpretability_net"],
      r["regional_net"],
      r["regional_material_decisions"],
      r["regional_q2_weight_sum_pct"]
    ]
  end
end

reallocations_path = OUTPUT_DIR.join("10_reallocations.csv")

CSV.open(reallocations_path, "w") do |csv|
  csv << [
    "scope",
    "action",
    "manager",
    "cusip",
    "issuer",
    "q1_shares",
    "q2_shares",
    "share_change",
    "q1_value",
    "q2_value",
    "portfolio_weight_pct",
    "interpretation"
  ]

  %w[NEW ADD REDUCE EXIT].each do |action|
    global_moves_by_action[action].each do |r|
      csv << [
        "GLOBAL_INTERPRETABLE",
        action,
        r["manager"],
        r["cusip"],
        r["issuer_name"],
        r["q1_shares"],
        r["q2_shares"],
        r["share_change"],
        r["q1_value"],
        r["q2_value"],
        nil,
        "Disclosed position change; values are quarter-end position values, not transaction proceeds."
      ]
    end
  end

  largest_regional_moves.each do |r|
    csv << [
      "REGIONAL",
      r[:action],
      r[:institution],
      r[:cusip],
      r[:issuer],
      nil,
      nil,
      nil,
      r[:q1_value],
      r[:q2_value],
      r[:q2_weight],
      "Regional disclosed position change; portfolio weight is Q2 observable 13F portfolio weight."
    ]
  end
end

puts "9. OUTPUT"
puts "---------"
puts answers_path
puts brief_path
puts reallocations_path
puts research_queue_path
puts
puts "Report complete."
