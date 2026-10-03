# frozen_string_literal: true

require "csv"
require "fileutils"

YEAR    = 2026
QUARTER = 2

ROOT       = File.expand_path("../..", __dir__)
OUTPUT_DIR = File.join(ROOT, "research", "output", "#{YEAR}-Q#{QUARTER}")

FileUtils.mkdir_p(OUTPUT_DIR)

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

def csv_rows(path)
  raise "Missing required research output: #{path}" unless File.exist?(path)

  CSV.read(path, headers: true).map(&:to_h)
end

def csv_row(path)
  csv_rows(path).first || {}
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

def pct(value, digits = 1)
  format("%.#{digits}f%%", value.to_f)
end

def normalize_label(value)
  value.to_s.strip.upcase
end

def directional_global(label)
  case normalize_label(label)
  when "BROAD_ACCUMULATION",
       "FUNDAMENTAL_ACCUMULATION",
       "FUNDAMENTAL_ACCUMULATION_BROAD_NEUTRAL",
       "DIVERGENT_BROAD_SELL_FUND_BUY"
    :positive
  when "BROAD_DISTRIBUTION",
       "FUNDAMENTAL_DISTRIBUTION",
       "FUNDAMENTAL_DISTRIBUTION_BROAD_NEUTRAL",
       "DIVERGENT_BROAD_BUY_FUND_SELL"
    :negative
  when "MIXED"
    :mixed
  else
    :limited
  end
end

def regional_direction(row)
  net = i(row["net"])

  return :positive if net.positive?
  return :negative if net.negative?

  :mixed
end

def evidence_state(global_row, regional_row)
  return "REGIONAL_ONLY" if global_row.nil?
  return "GLOBAL_ONLY" if regional_row.nil?

  g = directional_global(global_row["evidence_label"])
  r = regional_direction(regional_row)

  return "GLOBAL_AND_REGIONAL_ACCUMULATION" if g == :positive && r == :positive
  return "GLOBAL_AND_REGIONAL_DISTRIBUTION" if g == :negative && r == :negative
  return "GLOBAL_ACCUMULATION_REGIONAL_DISTRIBUTION" if g == :positive && r == :negative
  return "GLOBAL_DISTRIBUTION_REGIONAL_ACCUMULATION" if g == :negative && r == :positive
  return "GLOBAL_MIXED_REGIONAL_ACCUMULATION" if g == :mixed && r == :positive
  return "GLOBAL_MIXED_REGIONAL_DISTRIBUTION" if g == :mixed && r == :negative
  return "GLOBAL_ACCUMULATION_REGIONAL_MIXED" if g == :positive && r == :mixed
  return "GLOBAL_DISTRIBUTION_REGIONAL_MIXED" if g == :negative && r == :mixed
  return "LIMITED_GLOBAL_REGIONAL_ACCUMULATION" if g == :limited && r == :positive
  return "LIMITED_GLOBAL_REGIONAL_DISTRIBUTION" if g == :limited && r == :negative

  "MIXED_OR_LIMITED"
end

def escalation_bucket(row)
  state       = row[:evidence_state]
  fund_net    = row[:fundamental_net]
  hi_net      = row[:high_interpretability_net]
  regional_n  = row[:regional_net]
  material    = row[:regional_material_decisions]
  breadth     = row[:global_clean_breadth]

  if state == "GLOBAL_AND_REGIONAL_ACCUMULATION" &&
     (fund_net.positive? || hi_net.positive?) &&
     material.positive?
    "PRIORITY_RESEARCH"
  elsif state == "GLOBAL_AND_REGIONAL_DISTRIBUTION" &&
        (fund_net.negative? || hi_net.negative?) &&
        material.positive?
    "PRIORITY_RISK_REVIEW"
  elsif state.include?("REGIONAL_ACCUMULATION") &&
        state.include?("GLOBAL_DISTRIBUTION") &&
        material.positive?
    "DIVERGENCE_REVIEW"
  elsif state.include?("REGIONAL_DISTRIBUTION") &&
        state.include?("GLOBAL_ACCUMULATION") &&
        material.positive?
    "DIVERGENCE_REVIEW"
  elsif material.positive? && regional_n != 0
    "REGIONAL_MATERIAL_REVIEW"
  elsif (fund_net.abs >= 2 || hi_net.abs >= 2) && breadth >= 2
    "GLOBAL_SIGNAL_REVIEW"
  else
    "MONITOR"
  end
end

# -----------------------------------------------------------------------------
# Load validated research outputs
# -----------------------------------------------------------------------------

capital =
  csv_row(File.join(OUTPUT_DIR, "01_capital_universe_summary.csv"))

concentration =
  csv_row(File.join(OUTPUT_DIR, "02_capital_concentration_summary.csv"))

top_n =
  csv_rows(File.join(OUTPUT_DIR, "02_capital_concentration_top_n.csv"))

coverage =
  csv_rows(File.join(OUTPUT_DIR, "02_capital_concentration_coverage.csv"))

manager_signals =
  csv_rows(File.join(OUTPUT_DIR, "06_manager_signals.csv"))

manager_behavior =
  csv_rows(File.join(OUTPUT_DIR, "05_manager_behavior_summary.csv"))

security_signals =
  csv_rows(File.join(OUTPUT_DIR, "07_security_signals.csv"))

regional_capital =
  csv_rows(File.join(OUTPUT_DIR, "08_regional_institutional_capital.csv"))

regional_alignment =
  csv_rows(File.join(OUTPUT_DIR, "08_regional_security_alignment.csv"))

# -----------------------------------------------------------------------------
# Derived global capital statistics
# -----------------------------------------------------------------------------

total_capital = f(capital["total_reported_13f_value"])
manager_count = i(capital["managers"])

top_10 = top_n.find { |r| i(r["top_n_managers"]) == 10 }
top_25 = top_n.find { |r| i(r["top_n_managers"]) == 25 }
top_100 = top_n.find { |r| i(r["top_n_managers"]) == 100 }
top_500 = top_n.find { |r| i(r["top_n_managers"]) == 500 }

coverage_90 = coverage.find { |r| i(r["target_capital_pct"]) == 90 }
coverage_95 = coverage.find { |r| i(r["target_capital_pct"]) == 95 }

# -----------------------------------------------------------------------------
# Manager intelligence
# -----------------------------------------------------------------------------

classified_managers =
  manager_signals.reject { |r| normalize_label(r["archetype"]) == "UNCLASSIFIED" }

high_interpretability =
  manager_signals.select { |r| normalize_label(r["interpretability"]) == "HIGH" }

medium_interpretability =
  manager_signals.select { |r| normalize_label(r["interpretability"]) == "MEDIUM" }

ready_managers =
  manager_signals.select { |r| normalize_label(r["research_readiness"]) == "READY" }

comparable_behavior =
  manager_behavior.select { |r| normalize_label(r["comparison_status"]) == "COMPARABLE" }

behavior_quality_flags =
  manager_behavior.reject do |r|
    normalize_label(r["comparison_status"]) == "COMPARABLE" &&
      normalize_label(r["data_quality"]) == "OK"
  end

# -----------------------------------------------------------------------------
# Regional capital
# -----------------------------------------------------------------------------

regional_q1 = regional_capital.sum { |r| f(r["q1_reported_value"]) }
regional_q2 = regional_capital.sum { |r| f(r["q2_reported_value"]) }

regional_by_country =
  regional_capital
    .group_by { |r| r["country"] }
    .map do |country, rows|
      value = rows.sum { |r| f(r["q2_reported_value"]) }

      {
        country: country,
        institutions: rows.length,
        q2_value: value,
        share_pct: regional_q2.positive? ? value / regional_q2 * 100 : 0
      }
    end
    .sort_by { |r| -r[:q2_value] }

# -----------------------------------------------------------------------------
# Global / regional security join
# -----------------------------------------------------------------------------

global_by_cusip =
  security_signals.each_with_object({}) do |row, memo|
    cusip = normalize_label(row["cusip"])
    memo[cusip] = row unless cusip.empty?
  end

regional_by_cusip =
  regional_alignment.each_with_object({}) do |row, memo|
    cusip = normalize_label(row["cusip"])
    memo[cusip] = row unless cusip.empty?
  end

all_cusips = (global_by_cusip.keys + regional_by_cusip.keys).uniq

joined_signals =
  all_cusips.map do |cusip|
    g = global_by_cusip[cusip]
    r = regional_by_cusip[cusip]

    issuer =
      r&.fetch("issuer_name", nil).to_s.strip

    issuer =
      g&.fetch("issuer", nil).to_s.strip if issuer.empty?

    class_title =
      r&.fetch("class_title", nil).to_s.strip

    class_title =
      g&.fetch("class_title", nil).to_s.strip if class_title.empty?

    row = {
      cusip: cusip,
      issuer: issuer,
      class_title: class_title,

      global_evidence_label: g&.fetch("evidence_label", nil),
      global_manager_breadth: g ? i(g["manager_breadth"]) : 0,
      global_clean_breadth: g ? i(g["clean_manager_breadth"]) : 0,
      global_net: g ? i(g["clean_net"]) : 0,
      high_interpretability_net: g ? i(g["high_interpretability_net"]) : 0,
      fundamental_net: g ? i(g["fundamental_net"]) : 0,

      regional_institutions: r ? i(r["institutions"]) : 0,
      regional_countries: r ? i(r["countries"]) : 0,
      regional_positive: r ? i(r["positive"]) : 0,
      regional_negative: r ? i(r["negative"]) : 0,
      regional_net: r ? i(r["net"]) : 0,
      regional_material_decisions: r ? i(r["material_decisions"]) : 0,
      regional_q2_weight_sum_pct: r ? f(r["q2_weight_sum_pct"]) : 0.0
    }

    row[:evidence_state] = evidence_state(g, r)
    row[:escalation_bucket] = escalation_bucket(row)

    row
  end

# -----------------------------------------------------------------------------
# IC watchlist
# -----------------------------------------------------------------------------

watchlist =
  joined_signals
    .reject { |r| r[:escalation_bucket] == "MONITOR" }
    .sort_by do |r|
      priority =
        case r[:escalation_bucket]
        when "PRIORITY_RESEARCH" then 1
        when "PRIORITY_RISK_REVIEW" then 2
        when "DIVERGENCE_REVIEW" then 3
        when "REGIONAL_MATERIAL_REVIEW" then 4
        when "GLOBAL_SIGNAL_REVIEW" then 5
        else 6
        end

      [
        priority,
        -r[:regional_material_decisions],
        -r[:fundamental_net].abs,
        -r[:high_interpretability_net].abs,
        -r[:global_clean_breadth]
      ]
    end

# -----------------------------------------------------------------------------
# Evidence summaries
# -----------------------------------------------------------------------------

global_labels =
  security_signals
    .group_by { |r| r["evidence_label"] }
    .transform_values(&:length)
    .sort_by { |_k, v| -v }

evidence_states =
  joined_signals
    .select { |r| r[:regional_institutions].positive? }
    .group_by { |r| r[:evidence_state] }
    .transform_values(&:length)
    .sort_by { |_k, v| -v }

escalation_counts =
  watchlist
    .group_by { |r| r[:escalation_bucket] }
    .transform_values(&:length)
    .sort_by { |_k, v| -v }

# -----------------------------------------------------------------------------
# Terminal IC report
# -----------------------------------------------------------------------------

puts
puts "REPORT 09 — GLOBAL & REGIONAL INSTITUTIONAL CAPITAL REVIEW"
puts "=" * 65
puts "Portfolio period: Q#{QUARTER} #{YEAR}"
puts

puts "1. EXECUTIVE CAPITAL VIEW"
puts "-------------------------"
puts "Global 13F reporting entities: #{manager_count}"
puts "Global reported 13F value: #{money(total_capital)}"
puts "Median reporting entity: #{money(capital['median_reported_13f_value'])}"
puts "Effective reporting entities (HHI): #{format('%.1f', f(concentration['effective_managers']))}"
puts "Top 10 reporting entities control: #{pct(top_10 && top_10['pct_capital'])}"
puts "Top 100 reporting entities control: #{pct(top_100 && top_100['pct_capital'])}"
puts "Managers required for >=90% capital: #{coverage_90 && coverage_90['managers_required']}"
puts "Regional observable Q2 13F value: #{money(regional_q2)} across #{regional_capital.length} institutions"
puts

puts "2. GLOBAL CAPITAL STRUCTURE"
puts "---------------------------"
[
  top_10,
  top_25,
  top_100,
  top_500
].compact.each do |row|
  puts "Top #{row['top_n_managers']} | #{money(row['reported_13f_value'])} | #{pct(row['pct_capital'])} of reported capital"
end

puts
puts "90% capital coverage: #{coverage_90['managers_required']} managers"
puts "95% capital coverage: #{coverage_95['managers_required']} managers"
puts "Capital concentration HHI: #{format('%.6f', f(concentration['hhi']))}"
puts

puts "3. MANAGER INTELLIGENCE"
puts "-----------------------"
puts "Curated/classified managers: #{classified_managers.length}"
puts "HIGH interpretability: #{high_interpretability.length}"
puts "MEDIUM interpretability: #{medium_interpretability.length}"
puts "Research-ready managers: #{ready_managers.length}"
puts "Comparable QoQ manager histories: #{comparable_behavior.length}"
puts "Manager histories requiring caution: #{behavior_quality_flags.length}"

puts
puts "Research-ready manager set:"
ready_managers
  .sort_by { |r| i(r["global_rank"]) }
  .each do |r|
    puts [
      "##{r['global_rank']}",
      r["manager"],
      money(r["reported_13f_value"]),
      r["archetype"],
      "Interpretability=#{r['interpretability']}",
      "Signal=#{r['signal_use']}"
    ].join(" | ")
  end

puts
puts "4. MANAGER BEHAVIOR"
puts "-------------------"

manager_behavior
  .select { |r| normalize_label(r["comparison_status"]) == "COMPARABLE" }
  .sort_by do |r|
    -(i(r["new"]) + i(r["add"]) + i(r["reduce"]) + i(r["exit"]))
  end
  .first(15)
  .each do |r|
    puts [
      r["manager"],
      "NEW #{r['new']}",
      "ADD #{r['add']}",
      "REDUCE #{r['reduce']}",
      "EXIT #{r['exit']}",
      "DQ=#{r['data_quality']}"
    ].join(" | ")
  end

puts
puts "NOTE: Action counts are descriptive. They are not comparable measures of conviction"
puts "across managers with different mandates, portfolio breadth or disclosure structures."

puts
puts "5. GLOBAL SECURITY SIGNALS"
puts "--------------------------"

global_labels.each do |label, count|
  puts "#{label}: #{count}"
end

puts
puts "Highest fundamental accumulation evidence:"
security_signals
  .select { |r| i(r["fundamental_net"]).positive? }
  .sort_by do |r|
    [
      -i(r["fundamental_net"]),
      -i(r["high_interpretability_net"]),
      -i(r["clean_manager_breadth"])
    ]
  end
  .first(15)
  .each do |r|
    puts [
      r["issuer"],
      "Fund=#{r['fundamental_net']}",
      "HI=#{r['high_interpretability_net']}",
      "Net=#{r['clean_net']}",
      "Breadth=#{r['clean_manager_breadth']}",
      r["evidence_label"]
    ].join(" | ")
  end

puts
puts "Highest fundamental distribution evidence:"
security_signals
  .select { |r| i(r["fundamental_net"]).negative? }
  .sort_by do |r|
    [
      i(r["fundamental_net"]),
      i(r["high_interpretability_net"]),
      -i(r["clean_manager_breadth"])
    ]
  end
  .first(15)
  .each do |r|
    puts [
      r["issuer"],
      "Fund=#{r['fundamental_net']}",
      "HI=#{r['high_interpretability_net']}",
      "Net=#{r['clean_net']}",
      "Breadth=#{r['clean_manager_breadth']}",
      r["evidence_label"]
    ].join(" | ")
  end

puts
puts "6. GCC & IRAQ INSTITUTIONAL CAPITAL"
puts "-----------------------------------"
puts "Observable regional Q1 13F value: #{money(regional_q1)}"
puts "Observable regional Q2 13F value: #{money(regional_q2)}"
puts "13F reporting institutions in regional analytical set: #{regional_capital.length}"
puts "NOTE: Regional reported-value change is not portfolio performance."

puts
puts "Country distribution:"
regional_by_country.each do |r|
  puts "#{r[:country]} | #{money(r[:q2_value])} | #{pct(r[:share_pct])} | #{r[:institutions]} institutions"
end

puts
puts "Regional institution architecture:"
regional_capital
  .sort_by { |r| -f(r["q2_reported_value"]) }
  .each do |r|
    puts [
      r["country"],
      r["institution"],
      money(r["q2_reported_value"]),
      "#{r['q2_positions']} positions",
      "Top1 #{pct(r['q2_top1_pct'])}",
      "Eff #{format('%.1f', f(r['q2_effective_positions']))}",
      r["architecture_class"]
    ].join(" | ")
  end

puts
puts "7. GLOBAL VS REGIONAL ALIGNMENT"
puts "-------------------------------"

evidence_states.each do |state, count|
  puts "#{state}: #{count}"
end

puts
puts "Escalated cross-market evidence:"
watchlist
  .select { |r| r[:regional_institutions].positive? }
  .first(30)
  .each do |r|
    puts [
      r[:issuer],
      r[:evidence_state],
      r[:escalation_bucket],
      "Global=#{r[:global_evidence_label]}",
      "Fund=#{r[:fundamental_net]}",
      "HI=#{r[:high_interpretability_net]}",
      "Regional=#{r[:regional_net]}",
      "Material=#{r[:regional_material_decisions]}",
      "RegionalWeightSum=#{pct(r[:regional_q2_weight_sum_pct], 2)}"
    ].join(" | ")
  end

puts
puts "8. RISK & DATA QUALITY"
puts "----------------------"
puts "• 13F reported value is not institution AUM."
puts "• 13F portfolios are delayed disclosures and do not represent complete economic exposure."
puts "• Options, shorts, non-US assets and confidential treatment can materially alter interpretation."
puts "• Manager mandate and portfolio architecture must precede conviction inference."
puts "• Security actions are classified using reported units; corporate actions can still create false signals."
puts "• Regional alignment covers the identified reporting cohort, not all GCC or Iraqi institutional capital."
puts "• Regional combined weight is the sum of participating manager portfolio weights, not a regional portfolio weight."
puts "• Strategic holdings must not be interpreted as equivalent to diversified active-manager positions."
puts "• Report 05 turnover_proxy remains an activity proxy and is not an economically normalized turnover measure."
puts

puts "Manager data-quality exceptions:"
if behavior_quality_flags.empty?
  puts "None."
else
  behavior_quality_flags.each do |r|
    puts "#{r['manager']} | #{r['comparison_status']} | #{r['data_quality']} | #{r['status_reason']}"
  end
end

puts
puts "9. CAPITAL ALLOCATION IMPLICATIONS"
puts "----------------------------------"
puts "Evidence escalation counts:"
escalation_counts.each do |bucket, count|
  puts "#{bucket}: #{count}"
end

puts
puts "Priority research / risk / divergence queue:"
watchlist.first(30).each_with_index do |r, idx|
  puts [
    "#{idx + 1}. #{r[:issuer]}",
    r[:escalation_bucket],
    r[:evidence_state],
    "Fund=#{r[:fundamental_net]}",
    "HI=#{r[:high_interpretability_net]}",
    "Regional=#{r[:regional_net]}",
    "Material=#{r[:regional_material_decisions]}"
  ].join(" | ")
end

puts
puts "NOTE: Escalation means research priority, not investment recommendation."

puts
puts "10. INVESTMENT COMMITTEE QUESTIONS"
puts "----------------------------------"
puts "1. Which signals persist across multiple quarters rather than appearing once?"
puts "2. Which manager actions are economically material relative to their portfolio?"
puts "3. Where do high-interpretability fundamental managers disagree with broad institutional flows?"
puts "4. Where does GCC institutional behavior confirm or diverge from global institutional evidence?"
puts "5. Which regional positions reflect strategic ownership rather than portfolio-manager conviction?"
puts "6. Which signals survive corporate-action and disclosure-quality review?"
puts "7. Which escalated securities warrant fundamental valuation and downside analysis?"
puts "8. What subsequent 1Q, 2Q and 4Q performance follows each evidence state?"
puts "9. What evidence would justify allocating capital rather than continuing observation?"
puts "10. What could permanently impair capital if the thesis is wrong?"

# -----------------------------------------------------------------------------
# CSV outputs
# -----------------------------------------------------------------------------

alignment_path =
  File.join(OUTPUT_DIR, "09_global_regional_alignment.csv")

CSV.open(alignment_path, "w") do |csv|
  csv << [
    "cusip",
    "issuer",
    "class_title",
    "global_evidence_label",
    "global_manager_breadth",
    "global_clean_breadth",
    "global_net",
    "high_interpretability_net",
    "fundamental_net",
    "regional_institutions",
    "regional_countries",
    "regional_positive",
    "regional_negative",
    "regional_net",
    "regional_material_decisions",
    "regional_q2_weight_sum_pct",
    "evidence_state",
    "escalation_bucket"
  ]

  joined_signals.each do |r|
    csv << [
      r[:cusip],
      r[:issuer],
      r[:class_title],
      r[:global_evidence_label],
      r[:global_manager_breadth],
      r[:global_clean_breadth],
      r[:global_net],
      r[:high_interpretability_net],
      r[:fundamental_net],
      r[:regional_institutions],
      r[:regional_countries],
      r[:regional_positive],
      r[:regional_negative],
      r[:regional_net],
      r[:regional_material_decisions],
      r[:regional_q2_weight_sum_pct],
      r[:evidence_state],
      r[:escalation_bucket]
    ]
  end
end

watchlist_path =
  File.join(OUTPUT_DIR, "09_ic_watchlist.csv")

CSV.open(watchlist_path, "w") do |csv|
  csv << [
    "research_priority",
    "cusip",
    "issuer",
    "class_title",
    "escalation_bucket",
    "evidence_state",
    "global_evidence_label",
    "global_clean_breadth",
    "global_net",
    "high_interpretability_net",
    "fundamental_net",
    "regional_institutions",
    "regional_countries",
    "regional_net",
    "regional_material_decisions",
    "regional_q2_weight_sum_pct"
  ]

  watchlist.each_with_index do |r, idx|
    csv << [
      idx + 1,
      r[:cusip],
      r[:issuer],
      r[:class_title],
      r[:escalation_bucket],
      r[:evidence_state],
      r[:global_evidence_label],
      r[:global_clean_breadth],
      r[:global_net],
      r[:high_interpretability_net],
      r[:fundamental_net],
      r[:regional_institutions],
      r[:regional_countries],
      r[:regional_net],
      r[:regional_material_decisions],
      r[:regional_q2_weight_sum_pct]
    ]
  end
end

summary_path =
  File.join(OUTPUT_DIR, "09_ic_summary.csv")

CSV.open(summary_path, "w") do |csv|
  csv << [
    "portfolio_year",
    "portfolio_quarter",
    "global_managers",
    "global_reported_13f_value",
    "effective_managers",
    "top10_capital_pct",
    "top100_capital_pct",
    "managers_for_90pct_capital",
    "curated_managers",
    "research_ready_managers",
    "comparable_behavior_managers",
    "global_security_signals",
    "regional_13f_institutions",
    "regional_q2_reported_13f_value",
    "regional_security_alignment_rows",
    "ic_escalation_rows"
  ]

  csv << [
    YEAR,
    QUARTER,
    manager_count,
    total_capital,
    f(concentration["effective_managers"]),
    f(top_10["pct_capital"]),
    f(top_100["pct_capital"]),
    i(coverage_90["managers_required"]),
    classified_managers.length,
    ready_managers.length,
    comparable_behavior.length,
    security_signals.length,
    regional_capital.length,
    regional_q2,
    regional_alignment.length,
    watchlist.length
  ]
end

puts
puts "11. OUTPUT"
puts "----------"
puts summary_path
puts alignment_path
puts watchlist_path
puts
puts "Report complete."
