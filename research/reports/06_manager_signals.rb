require "csv"
require "yaml"
require "fileutils"

# ============================================================================
# REPORT 06 — MANAGER SIGNALS
#
# Research question:
#   Who are the institutional managers, what do we know about them,
#   and how should their observable 13F data be used?
#
# Principles:
#   - Cover the FULL manager universe.
#   - Capital importance != signal quality != interpretability.
#   - UNCLASSIFIED != LOW.
#   - Missing analysis is not a negative investment judgment.
#   - Do not collapse multidimensional manager intelligence into an
#     arbitrary composite score.
# ============================================================================

YEAR    = 2026
QUARTER = 2

OUTPUT_DIR = Rails.root.join(
  "research",
  "output",
  "#{YEAR}-Q#{QUARTER}"
)

OVERRIDES_PATH = Rails.root.join(
  "research",
  "cohorts",
  "manager_signal_overrides.yml"
)

BEHAVIOR_PATH = OUTPUT_DIR.join("05_manager_behavior_summary.csv")

FileUtils.mkdir_p(OUTPUT_DIR)

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

def money(value)
  value = value.to_f

  if value >= 1_000_000_000_000
    "$#{format('%.2f', value / 1_000_000_000_000.0)}T"
  elsif value >= 1_000_000_000
    "$#{format('%.2f', value / 1_000_000_000.0)}B"
  elsif value >= 1_000_000
    "$#{format('%.2f', value / 1_000_000.0)}M"
  elsif value >= 1_000
    "$#{format('%.2f', value / 1_000.0)}K"
  else
    "$#{format('%.2f', value)}"
  end
end

def pct(value)
  return "N/A" if value.nil?
  "#{format('%.2f', value * 100)}%"
end

def normalize_name(name)
  name.to_s.strip.upcase.gsub(/\s+/, " ")
end

def capital_tier(rank, value)
  value = value.to_f

  if rank <= 25
    "EXTREME_CAPITAL_CORE"
  elsif rank <= 100
    "MAJOR_CAPITAL"
  elsif rank <= 500
    "CORE_CAPITAL"
  elsif value >= 10_000_000_000
    "INSTITUTIONAL"
  elsif value >= 1_000_000_000
    "EXTENDED"
  else
    "FULL"
  end
end

def architecture_metrics(filing)
  return nil unless filing && filing.holdings.exists?

  positions = {}

  filing.holdings.where(option_type: nil).find_each do |holding|
    next if holding.cusip.blank?
    next unless holding.value.to_f > 0

    key = [
      holding.cusip.to_s.strip.upcase,
      holding.class_title.to_s.strip.upcase
    ]

    positions[key] ||= {
      value: 0.0,
      shares: 0.0
    }

    positions[key][:value] += holding.value.to_f
    positions[key][:shares] += holding.shares.to_f
  end

  values = positions.values
                    .map { |p| p[:value] }
                    .select(&:positive?)

  total = values.sum
  return nil if total <= 0

  weights = values.map { |v| v / total }.sort.reverse
  hhi = weights.sum { |w| w**2 }

  {
    long_value: total,
    positions: values.size,
    top10: weights.first(10).sum,
    hhi: hhi,
    effective_positions: hhi.positive? ? 1.0 / hhi : nil
  }
end

def selectivity_bucket(effective_positions)
  return "NOT_ANALYZED" if effective_positions.nil?

  case effective_positions
  when 0...10
    "VERY_HIGH_SELECTIVITY"
  when 10...25
    "HIGH_SELECTIVITY"
  when 25...75
    "MODERATE_SELECTIVITY"
  when 75...200
    "DIVERSIFIED"
  else
    "HIGHLY_DIVERSIFIED"
  end
end

def concentration_bucket(top10)
  return "NOT_ANALYZED" if top10.nil?

  if top10 >= 0.80
    "VERY_HIGH"
  elsif top10 >= 0.60
    "HIGH"
  elsif top10 >= 0.40
    "MODERATE"
  elsif top10 >= 0.20
    "LOW"
  else
    "VERY_LOW"
  end
end

def activity_bucket(turnover)
  return "NOT_ANALYZED" if turnover.nil?

  # TURN is still experimental and should be interpreted as a behavioral
  # activity proxy, not audited economic portfolio turnover.
  if turnover < 0.10
    "VERY_LOW"
  elsif turnover < 0.25
    "LOW"
  elsif turnover < 0.50
    "MODERATE"
  elsif turnover < 0.75
    "HIGH"
  else
    "VERY_HIGH"
  end
end

def data_depth(architecture_available, behavior_status)
  if behavior_status == "COMPARABLE"
    "BEHAVIOR"
  elsif architecture_available
    "ARCHITECTURE"
  else
    "CAPITAL_ONLY"
  end
end

def research_readiness(archetype:, interpretability:, architecture_available:,
                     behavior_status:, disclosure_quality:)
  # This is a readiness classification, NOT a manager-quality score.

  return "CAPITAL_ONLY" unless architecture_available

  return "CONTEXT_ONLY" if interpretability == "LOW"

  if behavior_status == "COMPARABLE" &&
     disclosure_quality == "OK" &&
     %w[HIGH MEDIUM].include?(interpretability)
    "READY"
  elsif %w[HIGH MEDIUM].include?(interpretability)
    "PARTIAL"
  elsif archetype != "UNCLASSIFIED"
    "PARTIAL"
  else
    "ARCHITECTURE_ONLY"
  end
end

# ----------------------------------------------------------------------------
# Load curated institutional overrides
# ----------------------------------------------------------------------------

override_yaml =
  if File.exist?(OVERRIDES_PATH)
    YAML.load_file(OVERRIDES_PATH) || {}
  else
    {}
  end

raw_overrides = override_yaml.fetch("managers", {})

overrides = {}

raw_overrides.each do |name, attributes|
  overrides[normalize_name(name)] = attributes
end

# ----------------------------------------------------------------------------
# Load Report 05 behavioral intelligence
# ----------------------------------------------------------------------------

behavior_by_cik = {}

if File.exist?(BEHAVIOR_PATH)
  CSV.foreach(BEHAVIOR_PATH, headers: true) do |row|
    behavior_by_cik[row["cik"].to_s] = {
      status: row["comparison_status"],
      status_reason: row["status_reason"],
      data_quality: row["data_quality"],
      q1_positions: row["q1_positions"],
      q2_positions: row["q2_positions"],
      new_count: row["new"],
      exit_count: row["exit"],
      add_count: row["add"],
      reduce_count: row["reduce"],
      unchanged_count: row["unchanged"],
      identity_changes: row["identity_change_candidates"],
      turnover_proxy: (
        row["turnover_proxy"].present? ?
          row["turnover_proxy"].to_f :
          nil
      )
    }
  end
end

# ----------------------------------------------------------------------------
# Build canonical Q2 manager universe
# ----------------------------------------------------------------------------

filings = ThirteenF
  .where(
    report_year: YEAR,
    report_quarter: QUARTER,
    restated_by_id: nil
  )
  .where.not(holdings_value_reported: nil)
  .order(cik: :asc, date_filed: :desc, id: :desc)
  .to_a
  .group_by(&:cik)
  .values
  .map(&:first)

filings.sort_by! { |f| -f.holdings_value_reported.to_f }

total_managers = filings.size
total_capital  = filings.sum { |f| f.holdings_value_reported.to_f }

rows = []

filings.each_with_index do |filing, index|
  rank = index + 1
  value = filing.holdings_value_reported.to_f

  percentile =
    if total_managers > 1
      1.0 - ((rank - 1).to_f / (total_managers - 1))
    else
      1.0
    end

  override = overrides[normalize_name(filing.name)] || {}

  archetype =
    override["archetype"].presence ||
    "UNCLASSIFIED"

  interpretability =
    override["interpretability"].presence ||
    "UNCLASSIFIED"

  signal_use =
    override["signal_use"].presence ||
    "UNCLASSIFIED"

  architecture = architecture_metrics(filing)

  behavior = behavior_by_cik[filing.cik.to_s]

  behavior_status =
    behavior ?
      behavior[:status] :
      "NOT_ANALYZED"

  disclosure_quality =
    behavior ?
      behavior[:data_quality] :
      "NOT_ANALYZED"

  architecture_available = !architecture.nil?

  depth = data_depth(
    architecture_available,
    behavior_status
  )

  readiness = research_readiness(
    archetype: archetype,
    interpretability: interpretability,
    architecture_available: architecture_available,
    behavior_status: behavior_status,
    disclosure_quality: disclosure_quality
  )

  rows << {
    rank: rank,
    percentile: percentile,
    cik: filing.cik,
    manager: filing.name,
    reported_value: value,
    capital_share: total_capital.positive? ? value / total_capital : nil,
    capital_tier: capital_tier(rank, value),

    holdings_loaded: filing.holdings.exists?,
    data_depth: depth,

    long_value: architecture && architecture[:long_value],
    positions: architecture && architecture[:positions],
    top10: architecture && architecture[:top10],
    hhi: architecture && architecture[:hhi],
    effective_positions: architecture && architecture[:effective_positions],

    selectivity: selectivity_bucket(
      architecture && architecture[:effective_positions]
    ),

    concentration: concentration_bucket(
      architecture && architecture[:top10]
    ),

    behavior_status: behavior_status,
    disclosure_quality: disclosure_quality,

    activity_proxy: behavior && behavior[:turnover_proxy],
    activity_bucket: activity_bucket(
      behavior && behavior[:turnover_proxy]
    ),

    archetype: archetype,
    interpretability: interpretability,
    signal_use: signal_use,
    signal_readiness: readiness
  }
end

# ----------------------------------------------------------------------------
# Output CSV
# ----------------------------------------------------------------------------

output_path = OUTPUT_DIR.join("06_manager_signals.csv")

CSV.open(output_path, "w") do |csv|
  csv << [
    "global_rank",
    "global_percentile",
    "cik",
    "manager",
    "reported_13f_value",
    "capital_share",
    "capital_tier",
    "holdings_loaded",
    "data_depth",
    "long_non_option_value",
    "positions",
    "top10_concentration",
    "hhi",
    "effective_positions",
    "selectivity",
    "concentration",
    "behavior_status",
    "disclosure_quality",
    "activity_proxy",
    "activity_bucket",
    "archetype",
    "interpretability",
    "research_readiness",
    "signal_use"
  ]

  rows.each do |r|
    csv << [
      r[:rank],
      r[:percentile],
      r[:cik],
      r[:manager],
      r[:reported_value],
      r[:capital_share],
      r[:capital_tier],
      r[:holdings_loaded],
      r[:data_depth],
      r[:long_value],
      r[:positions],
      r[:top10],
      r[:hhi],
      r[:effective_positions],
      r[:selectivity],
      r[:concentration],
      r[:behavior_status],
      r[:disclosure_quality],
      r[:activity_proxy],
      r[:activity_bucket],
      r[:archetype],
      r[:interpretability],
      r[:signal_readiness],
      r[:signal_use]
    ]
  end
end

# ----------------------------------------------------------------------------
# Terminal synthesis
# ----------------------------------------------------------------------------

puts
puts "REPORT 06 — MANAGER SIGNALS"
puts "==========================="
puts "Portfolio:             #{YEAR} Q#{QUARTER}"
puts "Managers:              #{rows.size}"
puts "Reported 13F value:    #{money(total_capital)}"
puts

puts "DATA DEPTH"
puts "----------"

rows.group_by { |r| r[:data_depth] }
    .sort_by { |name, _| name }
    .each do |name, group|
      puts "#{name.ljust(20)} #{group.size.to_s.rjust(5)}  #{pct(group.size.to_f / rows.size)}"
    end

puts
puts "CURATED CLASSIFICATION"
puts "----------------------"
puts "Archetype classified:      #{rows.count { |r| r[:archetype] != 'UNCLASSIFIED' }}"
puts "Interpretability assigned: #{rows.count { |r| r[:interpretability] != 'UNCLASSIFIED' }}"
puts "Unclassified managers:     #{rows.count { |r| r[:archetype] == 'UNCLASSIFIED' }}"
puts

puts "RESEARCH READINESS"
puts "----------------"

rows.group_by { |r| r[:signal_readiness] }
    .sort_by { |name, _| name }
    .each do |name, group|
      capital = group.sum { |r| r[:reported_value] }

      puts "#{name.ljust(20)} " \
           "#{group.size.to_s.rjust(5)} managers  " \
           "#{pct(capital / total_capital).rjust(8)} capital"
    end

puts
puts "CAPITAL TIERS"
puts "-------------"

tier_order = [
  "EXTREME_CAPITAL_CORE",
  "MAJOR_CAPITAL",
  "CORE_CAPITAL",
  "INSTITUTIONAL",
  "EXTENDED",
  "FULL"
]

tier_order.each do |tier|
  group = rows.select { |r| r[:capital_tier] == tier }
  next if group.empty?

  capital = group.sum { |r| r[:reported_value] }

  puts "#{tier.ljust(24)} " \
       "#{group.size.to_s.rjust(5)} managers  " \
       "#{pct(capital / total_capital).rjust(8)} capital"
end

puts
puts "DEEPLY ANALYZED MANAGERS"
puts "------------------------"

deep_rows = rows.select do |r|
  %w[BEHAVIOR ARCHITECTURE].include?(r[:data_depth])
end

deep_rows.each do |r|
  puts "#{r[:rank].to_s.rjust(4)}  " \
       "#{r[:manager].to_s[0,31].ljust(31)} " \
       "#{money(r[:reported_value]).rjust(10)}  " \
       "#{r[:archetype].to_s[0,26].ljust(26)}  " \
       "#{r[:interpretability].ljust(12)}  " \
       "#{r[:signal_readiness]}"
end

puts
puts "OUTPUT"
puts "------"
puts output_path
puts
puts "NOTE"
puts "----"
puts "Research readiness measures analytical data completeness, not manager or signal quality."
puts "UNCLASSIFIED means institutional context has not yet been curated."
puts "TURN/activity remains experimental pending an economically weighted replacement."
puts
