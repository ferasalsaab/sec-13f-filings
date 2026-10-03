require "csv"
require "fileutils"
require "date"

# ============================================================================
# REPORT 05 — MANAGER BEHAVIOR
#
# Research question:
#   What did each manager actually do with its disclosed long-equity portfolio
#   between Q1 and Q2 2026?
#
# Core principle:
#   Shares determine behavior. Values determine materiality.
#
# Behavior:
#   NEW       prior shares = 0, current shares > 0
#   EXIT      prior shares > 0, current shares = 0
#   ADD       current shares > prior shares
#   REDUCE    current shares < prior shares
#   UNCHANGED approximately equal shares
#
# Governance:
#   - CUSIP + option status identify comparable positions.
#   - Confidential/incomplete quarters are NOT_COMPARABLE.
#   - Missing prior data is never interpreted as NEW.
#   - Values are not used to classify ADD/REDUCE.
# ============================================================================

CURRENT_YEAR    = 2026
CURRENT_QUARTER = 2
PRIOR_YEAR      = 2026
PRIOR_QUARTER   = 1

CURRENT_REPORT_DATE = Date.new(2026, 6, 30)
PRIOR_REPORT_DATE   = Date.new(2026, 3, 31)

# Small tolerance protects against trivial parsing/rounding differences.
SHARE_TOLERANCE = 0.000001

OUTPUT_DIR = Rails.root.join(
  "research",
  "output",
  "#{CURRENT_YEAR}-Q#{CURRENT_QUARTER}"
)

FileUtils.mkdir_p(OUTPUT_DIR)

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

def money(value)
  value = value.to_f.abs

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
  "#{format('%.1f', value * 100)}%"
end

def safe_ratio(numerator, denominator)
  denominator = denominator.to_f
  return nil if denominator.zero?
  numerator.to_f / denominator
end

def approximately_equal?(a, b)
  (a.to_f - b.to_f).abs <= SHARE_TOLERANCE
end

def security_key(holding)
  [
    holding.cusip.to_s.strip.upcase,
    holding.option_type.to_s.strip.upcase
  ]
end

def aggregate_positions(filing)
  positions = {}

  filing.holdings.each do |holding|
    next if holding.cusip.blank?

    key = security_key(holding)

    positions[key] ||= {
      cusip: holding.cusip.to_s.strip.upcase,
      option_type: holding.option_type.to_s.strip.upcase,
      issuer_name: holding.issuer_name.to_s.strip,
      class_title: holding.class_title.to_s.strip,
      shares: 0.0,
      value: 0.0
    }

    positions[key][:shares] += holding.shares.to_f
    positions[key][:value]  += holding.value.to_f

    if positions[key][:issuer_name].blank? && holding.issuer_name.present?
      positions[key][:issuer_name] = holding.issuer_name.to_s.strip
    end

    if positions[key][:class_title].blank? && holding.class_title.present?
      positions[key][:class_title] = holding.class_title.to_s.strip
    end
  end

  positions
end

def long_positions(positions)
  positions.select do |_key, position|
    position[:option_type].blank? &&
      position[:shares].to_f > 0 &&
      position[:value].to_f > 0
  end
end

def architecture(positions)
  values = positions.values.map { |p| p[:value].to_f }.select(&:positive?)
  total = values.sum

  return {
    value: 0.0,
    positions: 0,
    top10: nil,
    hhi: nil,
    effective_positions: nil
  } if total <= 0

  weights = values.map { |v| v / total }.sort.reverse
  hhi = weights.sum { |w| w**2 }

  {
    value: total,
    positions: values.size,
    top10: weights.first(10).sum,
    hhi: hhi,
    effective_positions: hhi.positive? ? 1.0 / hhi : nil
  }
end

def canonical_filing(year:, quarter:, cik:)
  ThirteenF
    .where(
      cik: cik,
      report_year: year,
      report_quarter: quarter,
      restated_by_id: nil
    )
    .order(date_filed: :desc, id: :desc)
    .detect { |f| f.holdings.exists? }
end

def comparison_status(prior, current)
  return ["NOT_COMPARABLE", "MISSING_PRIOR"] if prior.nil?
  return ["NOT_COMPARABLE", "MISSING_CURRENT"] if current.nil?

  unless prior.holdings.exists?
    return ["NOT_COMPARABLE", "PRIOR_HOLDINGS_NOT_LOADED"]
  end

  unless current.holdings.exists?
    return ["NOT_COMPARABLE", "CURRENT_HOLDINGS_NOT_LOADED"]
  end

  if prior.report_date != PRIOR_REPORT_DATE
    return ["NOT_COMPARABLE", "WRONG_PRIOR_REPORT_DATE"]
  end

  if current.report_date != CURRENT_REPORT_DATE
    return ["NOT_COMPARABLE", "WRONG_CURRENT_REPORT_DATE"]
  end

  if prior.confidential_omitted == true
    return ["NOT_COMPARABLE", "Q1_CONFIDENTIAL_TREATMENT"]
  end

  if current.confidential_omitted == true
    return ["NOT_COMPARABLE", "Q2_CONFIDENTIAL_TREATMENT"]
  end

  # Filing completeness check.
  #
  # A large discrepancy between reported and calculated holdings indicates
  # that the information table available to us may not represent the full
  # disclosed portfolio.
  if prior.holdings_count_reported.to_i > 0 &&
     prior.holdings_count_calculated.to_i > 0 &&
     prior.holdings_count_calculated.to_f / prior.holdings_count_reported.to_f < 0.95

    return ["NOT_COMPARABLE", "Q1_INCOMPLETE_HOLDINGS"]
  end

  if current.holdings_count_reported.to_i > 0 &&
     current.holdings_count_calculated.to_i > 0 &&
     current.holdings_count_calculated.to_f / current.holdings_count_reported.to_f < 0.95

    return ["NOT_COMPARABLE", "Q2_INCOMPLETE_HOLDINGS"]
  end

  ["COMPARABLE", "OK"]
end

def disclosure_flag(prior, current)
  return nil unless prior && current

  prior_value   = prior.holdings_value_reported.to_f
  current_value = current.holdings_value_reported.to_f

  prior_count   = prior.holdings_count_reported.to_i
  current_count = current.holdings_count_reported.to_i

  value_ratio =
    if prior_value.positive? && current_value.positive?
      [current_value / prior_value, prior_value / current_value].max
    end

  count_ratio =
    if prior_count.positive? && current_count.positive?
      [
        current_count.to_f / prior_count,
        prior_count.to_f / current_count
      ].max
    end

  # This does not make the quarter non-comparable automatically.
  # It tells the analyst that the disclosure changed dramatically.
  if (value_ratio && value_ratio >= 5.0) ||
     (count_ratio && count_ratio >= 5.0)
    "DISCLOSURE_DISCONTINUITY"
  else
    "OK"
  end
end

def classify_changes(prior_positions, current_positions)
  keys = prior_positions.keys | current_positions.keys

  keys.map do |key|
    prior   = prior_positions[key]
    current = current_positions[key]

    prior_shares   = prior ? prior[:shares].to_f : 0.0
    current_shares = current ? current[:shares].to_f : 0.0

    action =
      if prior_shares <= SHARE_TOLERANCE &&
         current_shares > SHARE_TOLERANCE
        "NEW"
      elsif prior_shares > SHARE_TOLERANCE &&
            current_shares <= SHARE_TOLERANCE
        "EXIT"
      elsif approximately_equal?(prior_shares, current_shares)
        "UNCHANGED"
      elsif current_shares > prior_shares
        "ADD"
      else
        "REDUCE"
      end

    reference = current || prior

    {
      key: key,
      cusip: reference[:cusip],
      option_type: reference[:option_type],
      issuer_name: reference[:issuer_name],
      class_title: reference[:class_title],
      action: action,
      prior_shares: prior_shares,
      current_shares: current_shares,
      share_change: current_shares - prior_shares,
      prior_value: prior ? prior[:value].to_f : 0.0,
      current_value: current ? current[:value].to_f : 0.0
    }
  end
end

def normalized_issuer_name(name)
  name.to_s
      .upcase
      .gsub(/[^A-Z0-9 ]/, " ")
      .gsub(/\\b(INC|INCORPORATED|CORP|CORPORATION|CO|COMPANY|PLC|LTD|LIMITED|DEL|NEW|CLASS|CL|COM|COMMON|STOCK)\\b/, " ")
      .gsub(/\\s+/, " ")
      .strip
end

def flag_identity_change_candidates(changes)
  exits = changes.select { |c| c[:action] == "EXIT" }
  news  = changes.select { |c| c[:action] == "NEW" }

  exits_by_name = exits.group_by do |c|
    normalized_issuer_name(c[:issuer_name])
  end

  news_by_name = news.group_by do |c|
    normalized_issuer_name(c[:issuer_name])
  end

  candidate_names = (exits_by_name.keys & news_by_name.keys).reject(&:blank?)

  candidate_names.each do |name|
    old_positions = exits_by_name[name]
    new_positions = news_by_name[name]

    # Conservative governance rule:
    # Only auto-flag when the normalized issuer maps uniquely to one EXIT
    # and one NEW for this manager. One-to-many ETF/fund structures remain
    # unresolved and retain their original actions.
    next unless old_positions.size == 1 && new_positions.size == 1

    old_position = old_positions.first
    new_position = new_positions.first

    old_position[:original_action] = "EXIT"
    new_position[:original_action] = "NEW"

    old_position[:action] = "IDENTITY_CHANGE_CANDIDATE"
    new_position[:action] = "IDENTITY_CHANGE_CANDIDATE"
  end

  changes
end

def turnover_proxy(changes)
  behavioral_changes = changes.reject do |change|
    change[:action] == "IDENTITY_CHANGE_CANDIDATE"
  end

  denominator = behavioral_changes.sum do |change|
    (change[:prior_shares].abs + change[:current_shares].abs) / 2.0
  end

  numerator = behavioral_changes.sum { |change| change[:share_change].abs }

  safe_ratio(numerator, denominator)
end

def top_change(changes, action)
  candidates = changes.select { |c| c[:action] == action }

  case action
  when "NEW", "ADD"
    candidates.max_by { |c| c[:current_value] }
  when "EXIT", "REDUCE"
    candidates.max_by { |c| c[:prior_value] }
  end
end

def change_label(change)
  return "" unless change

  name = change[:issuer_name].presence || change[:cusip]

  value =
    if %w[NEW ADD].include?(change[:action])
      change[:current_value]
    else
      change[:prior_value]
    end

  "#{name} (#{money(value)})"
end

# ----------------------------------------------------------------------------
# Establish current research cohort
# ----------------------------------------------------------------------------

current_candidates = ThirteenF
  .where(
    report_year: CURRENT_YEAR,
    report_quarter: CURRENT_QUARTER,
    restated_by_id: nil
  )
  .order(cik: :asc, date_filed: :desc, id: :desc)
  .to_a
  .group_by(&:cik)
  .values
  .map { |filings| filings.detect { |f| f.holdings.exists? } }
  .compact

# Only managers whose Q2 holdings have actually been materialised.
cohort = current_candidates.select { |f| f.holdings.exists? }

results = []
detail_rows = []

cohort.each do |current|
  prior = canonical_filing(
    year: PRIOR_YEAR,
    quarter: PRIOR_QUARTER,
    cik: current.cik
  )

  status, status_reason = comparison_status(prior, current)
  quality_flag = disclosure_flag(prior, current)

  row = {
    manager: current.name,
    cik: current.cik,
    status: status,
    status_reason: status_reason,
    data_quality: quality_flag || status_reason,
    q1_reported_value: prior&.holdings_value_reported,
    q2_reported_value: current.holdings_value_reported,
    q1_positions: nil,
    q2_positions: nil,
    new_count: nil,
    exit_count: nil,
    add_count: nil,
    reduce_count: nil,
    unchanged_count: nil,
    identity_change_count: nil,
    turnover_proxy: nil,
    q1_top10: nil,
    q2_top10: nil,
    top10_delta: nil,
    q1_effective_positions: nil,
    q2_effective_positions: nil,
    effective_positions_delta: nil,
    largest_new: "",
    largest_add: "",
    largest_reduce: "",
    largest_exit: ""
  }

  if status == "COMPARABLE"
    prior_all   = aggregate_positions(prior)
    current_all = aggregate_positions(current)

    # Report 05 behavior focuses on long, non-option positions.
    prior_long   = long_positions(prior_all)
    current_long = long_positions(current_all)

    changes = classify_changes(prior_long, current_long)
    changes = flag_identity_change_candidates(changes)

    prior_arch   = architecture(prior_long)
    current_arch = architecture(current_long)

    counts = changes.group_by { |c| c[:action] }
                    .transform_values(&:size)

    row.merge!(
      q1_positions: prior_arch[:positions],
      q2_positions: current_arch[:positions],
      new_count: counts.fetch("NEW", 0),
      exit_count: counts.fetch("EXIT", 0),
      add_count: counts.fetch("ADD", 0),
      reduce_count: counts.fetch("REDUCE", 0),
      unchanged_count: counts.fetch("UNCHANGED", 0),
      identity_change_count: counts.fetch("IDENTITY_CHANGE_CANDIDATE", 0) / 2,
      turnover_proxy: turnover_proxy(changes),
      q1_top10: prior_arch[:top10],
      q2_top10: current_arch[:top10],
      top10_delta: (
        current_arch[:top10] && prior_arch[:top10] ?
          current_arch[:top10] - prior_arch[:top10] :
          nil
      ),
      q1_effective_positions: prior_arch[:effective_positions],
      q2_effective_positions: current_arch[:effective_positions],
      effective_positions_delta: (
        current_arch[:effective_positions] &&
        prior_arch[:effective_positions] ?
          current_arch[:effective_positions] -
            prior_arch[:effective_positions] :
          nil
      ),
      largest_new: change_label(top_change(changes, "NEW")),
      largest_add: change_label(top_change(changes, "ADD")),
      largest_reduce: change_label(top_change(changes, "REDUCE")),
      largest_exit: change_label(top_change(changes, "EXIT"))
    )

    changes.each do |change|
      detail_rows << {
        manager: current.name,
        cik: current.cik,
        cusip: change[:cusip],
        option_type: change[:option_type],
        issuer_name: change[:issuer_name],
        class_title: change[:class_title],
        action: change[:action],
        q1_shares: change[:prior_shares],
        q2_shares: change[:current_shares],
        share_change: change[:share_change],
        q1_value: change[:prior_value],
        q2_value: change[:current_value],
        data_quality: row[:data_quality]
      }
    end
  end

  results << row
end

# Sort by current reported 13F value.
results.sort_by! { |r| -r[:q2_reported_value].to_f }

# ----------------------------------------------------------------------------
# CSV outputs
# ----------------------------------------------------------------------------

summary_path = OUTPUT_DIR.join("05_manager_behavior_summary.csv")
detail_path  = OUTPUT_DIR.join("05_manager_behavior_detail.csv")

CSV.open(summary_path, "w") do |csv|
  csv << [
    "manager",
    "cik",
    "comparison_status",
    "status_reason",
    "data_quality",
    "q1_reported_value",
    "q2_reported_value",
    "q1_positions",
    "q2_positions",
    "new",
    "exit",
    "add",
    "reduce",
    "unchanged",
    "identity_change_candidates",
    "turnover_proxy",
    "q1_top10",
    "q2_top10",
    "top10_delta",
    "q1_effective_positions",
    "q2_effective_positions",
    "effective_positions_delta",
    "largest_new",
    "largest_add",
    "largest_reduce",
    "largest_exit"
  ]

  results.each do |r|
    csv << [
      r[:manager],
      r[:cik],
      r[:status],
      r[:status_reason],
      r[:data_quality],
      r[:q1_reported_value],
      r[:q2_reported_value],
      r[:q1_positions],
      r[:q2_positions],
      r[:new_count],
      r[:exit_count],
      r[:add_count],
      r[:reduce_count],
      r[:unchanged_count],
      r[:identity_change_count],
      r[:turnover_proxy],
      r[:q1_top10],
      r[:q2_top10],
      r[:top10_delta],
      r[:q1_effective_positions],
      r[:q2_effective_positions],
      r[:effective_positions_delta],
      r[:largest_new],
      r[:largest_add],
      r[:largest_reduce],
      r[:largest_exit]
    ]
  end
end

CSV.open(detail_path, "w") do |csv|
  csv << [
    "manager",
    "cik",
    "cusip",
    "option_type",
    "issuer_name",
    "class_title",
    "action",
    "q1_shares",
    "q2_shares",
    "share_change",
    "q1_value",
    "q2_value",
    "data_quality"
  ]

  detail_rows.each do |r|
    csv << [
      r[:manager],
      r[:cik],
      r[:cusip],
      r[:option_type],
      r[:issuer_name],
      r[:class_title],
      r[:action],
      r[:q1_shares],
      r[:q2_shares],
      r[:share_change],
      r[:q1_value],
      r[:q2_value],
      r[:data_quality]
    ]
  end
end

# ----------------------------------------------------------------------------
# Terminal report
# ----------------------------------------------------------------------------

comparable = results.count { |r| r[:status] == "COMPARABLE" }
excluded   = results.size - comparable
flagged    = results.count do |r|
  r[:status] == "COMPARABLE" && r[:data_quality] != "OK"
end

puts
puts "REPORT 05 — MANAGER BEHAVIOR"
puts "============================"
puts "Prior portfolio:      #{PRIOR_YEAR} Q#{PRIOR_QUARTER}"
puts "Current portfolio:    #{CURRENT_YEAR} Q#{CURRENT_QUARTER}"
puts "Research managers:    #{results.size}"
puts "Comparable:           #{comparable}"
puts "Not comparable:       #{excluded}"
puts "Comparable + flagged: #{flagged}"
puts

puts "#{"MANAGER".ljust(31)} #{"STATUS".ljust(15)} #{"Q1".rjust(5)} #{"Q2".rjust(5)} #{"NEW".rjust(5)} #{"EXIT".rjust(5)} #{"ADD".rjust(5)} #{"RED".rjust(5)} #{"SAME".rjust(5)} #{"IDΔ".rjust(5)} #{"TURN".rjust(7)} #{"T10Δ".rjust(7)} #{"EFFΔ".rjust(8)} QUALITY"

results.each do |r|
  if r[:status] == "COMPARABLE"
    puts "#{r[:manager].to_s[0,31].ljust(31)} " \
         "#{r[:status].ljust(15)} " \
         "#{r[:q1_positions].to_i.to_s.rjust(5)} " \
         "#{r[:q2_positions].to_i.to_s.rjust(5)} " \
         "#{r[:new_count].to_i.to_s.rjust(5)} " \
         "#{r[:exit_count].to_i.to_s.rjust(5)} " \
         "#{r[:add_count].to_i.to_s.rjust(5)} " \
         "#{r[:reduce_count].to_i.to_s.rjust(5)} " \
         "#{r[:unchanged_count].to_i.to_s.rjust(5)} " \
         "#{r[:identity_change_count].to_i.to_s.rjust(5)} " \
         "#{pct(r[:turnover_proxy]).rjust(7)} " \
         "#{pct(r[:top10_delta]).rjust(7)} " \
         "#{format('%.1f', r[:effective_positions_delta].to_f).rjust(8)} " \
         "#{r[:data_quality]}"
  else
    puts "#{r[:manager].to_s[0,31].ljust(31)} " \
         "#{r[:status].ljust(15)} " \
         "#{"-".rjust(5)} " \
         "#{"-".rjust(5)} " \
         "#{"-".rjust(5)} " \
         "#{"-".rjust(5)} " \
         "#{"-".rjust(5)} " \
         "#{"-".rjust(5)} " \
         "#{"-".rjust(5)} " \
         "#{"-".rjust(5)} " \
         "#{"-".rjust(7)} " \
         "#{"-".rjust(7)} " \
         "#{"-".rjust(8)} " \
         "#{r[:status_reason]}"
  end
end

puts
puts "LARGEST DISCLOSED DECISIONS"
puts "==========================="

results
  .select { |r| r[:status] == "COMPARABLE" }
  .each do |r|
    puts
    puts r[:manager]
    puts "  NEW:     #{r[:largest_new].presence || '-'}"
    puts "  ADD:     #{r[:largest_add].presence || '-'}"
    puts "  REDUCE:  #{r[:largest_reduce].presence || '-'}"
    puts "  EXIT:    #{r[:largest_exit].presence || '-'}"
  end

puts
puts "OUTPUT"
puts "======"
puts summary_path
puts detail_path
puts
