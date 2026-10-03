# frozen_string_literal: true

require "yaml"
require "csv"

YEAR    = 2026
QUARTER = 2

ROOT     = File.expand_path("../..", __dir__)
REGISTRY = File.join(ROOT, "research/cohorts/regional_institutions.yml")
OUTPUT   = File.join(ROOT, "research/output/#{YEAR}-Q#{QUARTER}")

FileUtils.mkdir_p(OUTPUT)

registry = YAML.load_file(REGISTRY)

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

def money(value)
  value = value.to_f
  return "$#{format('%.2f', value / 1_000_000_000_000.0)}T" if value >= 1_000_000_000_000
  return "$#{format('%.2f', value / 1_000_000_000.0)}B" if value >= 1_000_000_000
  return "$#{format('%.2f', value / 1_000_000.0)}M" if value >= 1_000_000
  return "$#{format('%.2f', value / 1_000.0)}K" if value >= 1_000

  "$#{format('%.2f', value)}"
end

def pct(value)
  "#{format('%.1f', value.to_f)}%"
end

def canonical_filing(cik, year, quarter)
  filings = ThirteenF
    .where(
      cik: cik,
      report_year: year,
      report_quarter: quarter
    )
    .order(date_filed: :desc, id: :desc)
    .to_a

  return nil if filings.empty?

  # Prefer the latest filing that actually contains holdings.
  # This prevents an administrative amendment with no usable
  # information table from displacing a complete original filing.
  filings.find { |f| f.holdings.exists? } || filings.first
end

def long_positions(filing)
  return [] unless filing

  filing.aggregate_holdings
    .where(option_type: [nil, ""])
    .where("shares_or_principal_amount > 0")
    .where("value > 0")
    .to_a
end

def architecture_classification(a)
  return "NO_DATA" if a[:positions].zero?
  return "SINGLE_POSITION_STRATEGIC" if a[:positions] == 1
  return "STRATEGIC_DOMINATED" if a[:top1] >= 50
  return "CONCENTRATED" if a[:effective_positions] < 10
  return "MODERATELY_DIVERSIFIED" if a[:effective_positions] < 50

  "DIVERSIFIED"
end

def architecture(positions)
  total = positions.sum { |h| h.value.to_f }

  return {
    total: 0,
    positions: 0,
    top1: 0,
    top5: 0,
    top10: 0,
    top20: 0,
    hhi: 0,
    effective_positions: 0
  } if total <= 0

  weights = positions
    .map { |h| h.value.to_f / total }
    .sort
    .reverse

  hhi = weights.sum { |w| w * w }

  {
    total: total,
    positions: weights.size,
    top1: weights.first.to_f * 100,
    top5: weights.first(5).sum * 100,
    top10: weights.first(10).sum * 100,
    top20: weights.first(20).sum * 100,
    hhi: hhi,
    effective_positions: hhi.zero? ? 0 : 1.0 / hhi
  }
end

# ------------------------------------------------------------
# Load regional 13F institutions
# ------------------------------------------------------------

institutions = []

registry.fetch("regions").each do |region, countries|
  countries.each do |country, entries|
    entries.each do |entry|
      next unless entry["disclosure_scope"] == "13F_MANAGER"

      cik = entry["cik"]

      q1 = canonical_filing(cik, YEAR, 1)
      q2 = canonical_filing(cik, YEAR, QUARTER)

      q1_positions = long_positions(q1)
      q2_positions = long_positions(q2)

      q1_arch = architecture(q1_positions)
      q2_arch = architecture(q2_positions)

      institutions << {
        region: region,
        country: country,
        institution: entry["institution"],
        manager_name: entry["manager_name"],
        cik: cik,
        institution_type: entry["institution_type"],

        q1_filing: q1,
        q2_filing: q2,

        q1_positions: q1_positions,
        q2_positions: q2_positions,

        q1_arch: q1_arch,
        q2_arch: q2_arch
      }
    end
  end
end

# ------------------------------------------------------------
# Regional totals
# ------------------------------------------------------------

puts
puts "REPORT 08 — GCC & IRAQ INSTITUTIONAL CAPITAL INTELLIGENCE"
puts "=========================================================="
puts "Period: Q2 #{YEAR}"
puts

puts "1. REGIONAL 13F CAPITAL"
puts "-----------------------"

q2_total = institutions.sum do |x|
  x[:q2_filing]&.holdings_value_reported.to_f
end

q1_total = institutions.sum do |x|
  x[:q1_filing]&.holdings_value_reported.to_f
end

puts "13F institutions: #{institutions.size}"
puts "Q1 reported 13F value: #{money(q1_total)}"
puts "Q2 reported 13F value: #{money(q2_total)}"

if q1_total > 0
  change = ((q2_total / q1_total) - 1) * 100
  puts "Reported-value change: #{pct(change)}"
end

puts "NOTE: Reported-value change is not investment performance."
puts "It combines security-price movements, purchases/sales, new/removed positions,"
puts "and changes in the observable 13F portfolio."

puts

# ------------------------------------------------------------
# Country capital
# ------------------------------------------------------------

puts "2. COUNTRY CAPITAL"
puts "------------------"

institutions
  .group_by { |x| x[:country] }
  .sort_by do |_country, rows|
    -rows.sum { |x| x[:q2_filing]&.holdings_value_reported.to_f }
  end
  .each do |country, rows|

  value = rows.sum { |x| x[:q2_filing]&.holdings_value_reported.to_f }

  share = q2_total.zero? ? 0 : value / q2_total * 100

  puts "#{country}: #{money(value)} | #{pct(share)} | #{rows.size} institutions"
end

puts

# ------------------------------------------------------------
# Institution architecture
# ------------------------------------------------------------

puts "3. INSTITUTION ARCHITECTURE"
puts "---------------------------"

institutions
  .sort_by { |x| -x[:q2_arch][:total] }
  .each do |x|

  a = x[:q2_arch]

  puts [
    x[:country],
    x[:institution],
    money(a[:total]),
    "#{a[:positions]} positions",
    "Top1 #{pct(a[:top1])}",
    "Top5 #{pct(a[:top5])}",
    "Top10 #{pct(a[:top10])}",
    "Eff #{format('%.1f', a[:effective_positions])}",
    architecture_classification(a)
  ].join(" | ")
end

puts

# ------------------------------------------------------------
# QoQ actions
# ------------------------------------------------------------

puts "4. QOQ PORTFOLIO BEHAVIOR"
puts "-------------------------"

behavior_rows = []

institutions.each do |x|
  # CUSIP is the primary security identity.
  # class_title is deliberately excluded because SEC filers frequently
  # change descriptive class-title text between quarters without any
  # economic change in the security.
  #
  # option_type and unit type remain in the key because they can represent
  # economically different exposures / measurement units.
  q1 = x[:q1_positions].index_by do |h|
    [
      h.cusip.to_s.strip.upcase,
      h.option_type.to_s.strip.upcase,
      h.shares_or_principal_amount_type.to_s.strip.upcase
    ]
  end

  q2 = x[:q2_positions].index_by do |h|
    [
      h.cusip.to_s.strip.upcase,
      h.option_type.to_s.strip.upcase,
      h.shares_or_principal_amount_type.to_s.strip.upcase
    ]
  end

  keys = (q1.keys + q2.keys).uniq

  counts = Hash.new(0)

  keys.each do |key|
    before = q1[key]
    after  = q2[key]

    before_shares = before&.shares_or_principal_amount.to_f
    after_shares  = after&.shares_or_principal_amount.to_f

    action =
      if before.nil? && after
        "NEW"
      elsif before && after.nil?
        "EXIT"
      elsif after_shares > before_shares
        "ADD"
      elsif after_shares < before_shares
        "REDUCE"
      else
        "UNCHANGED"
      end

    counts[action] += 1

    security = after || before

    behavior_rows << {
      region: x[:region],
      country: x[:country],
      institution: x[:institution],
      cik: x[:cik],
      cusip: security.cusip,
      issuer_name: security.issuer_name,
      class_title: security.class_title,
      action: action,
      q1_shares: before_shares,
      q2_shares: after_shares,
      q1_value: before&.value.to_f,
      q2_value: after&.value.to_f,
      manager_q2_portfolio_value: x[:q2_arch][:total],
      q2_position_weight_pct: (
        x[:q2_arch][:total].to_f > 0 ?
          after&.value.to_f / x[:q2_arch][:total].to_f * 100 :
          0
      )
    }
  end

  puts [
    x[:institution],
    "NEW #{counts['NEW']}",
    "EXIT #{counts['EXIT']}",
    "ADD #{counts['ADD']}",
    "REDUCE #{counts['REDUCE']}",
    "UNCHANGED #{counts['UNCHANGED']}"
  ].join(" | ")
end

puts

# ------------------------------------------------------------
# Regional security consensus
# ------------------------------------------------------------

puts "5. REGIONAL SECURITY ALIGNMENT"
puts "------------------------------"

security_rows = behavior_rows
  .reject { |r| r[:action] == "UNCHANGED" }
  .group_by { |r| r[:cusip].to_s.strip.upcase }
  .map do |key, rows|

  positive = rows.count { |r| %w[NEW ADD].include?(r[:action]) }
  negative = rows.count { |r| %w[EXIT REDUCE].include?(r[:action]) }

  {
    cusip: key,
    class_title: rows.first[:class_title],
    issuer_name: rows.first[:issuer_name],
    decisions: rows.size,
    institutions: rows.map { |r| r[:institution] }.uniq.size,
    countries: rows.map { |r| r[:country] }.uniq.size,
    positive: positive,
    negative: negative,
    net: positive - negative,
    material_decisions: rows.count { |r| r[:q2_position_weight_pct].to_f >= 1.0 },
    q2_weight_sum_pct: rows.sum { |r| r[:q2_position_weight_pct].to_f }
  }
end

security_rows
  .select { |r| r[:institutions] >= 2 }
  .sort_by { |r| [-r[:institutions], -r[:net].abs, r[:issuer_name].to_s] }
  .first(30)
  .each do |r|

  direction =
    if r[:net] > 0
      "ACCUMULATION"
    elsif r[:net] < 0
      "DISTRIBUTION"
    else
      "MIXED"
    end

  puts [
    r[:issuer_name],
    r[:class_title],
    "#{r[:institutions]} institutions",
    "#{r[:countries]} countries",
    "positive=#{r[:positive]}",
    "negative=#{r[:negative]}",
    "net=#{r[:net]}",
    "material=#{r[:material_decisions]}",
    "combined_q2_weight=#{format('%.2f', r[:q2_weight_sum_pct])}%",
    direction
  ].join(" | ")
end

puts

# ------------------------------------------------------------
# Wider institutional perimeter
# ------------------------------------------------------------

puts "6. WIDER REGIONAL INSTITUTIONAL PERIMETER"
puts "------------------------------------------"

registry.fetch("regions").each do |region, countries|
  countries.each do |country, entries|
    entries.each do |entry|
      next if entry["disclosure_scope"] == "13F_MANAGER"

      puts [
        region,
        country,
        entry["institution"],
        entry["institution_type"],
        entry["disclosure_scope"],
        entry["research_priority"],
        entry["identity_status"]
      ].join(" | ")
    end
  end
end

puts

# ------------------------------------------------------------
# CSV outputs
# ------------------------------------------------------------

summary_path = File.join(
  OUTPUT,
  "08_regional_institutional_capital.csv"
)

CSV.open(summary_path, "w") do |csv|
  csv << %w[
    region
    country
    institution
    cik
    institution_type
    q1_reported_value
    q2_reported_value
    q1_positions
    q2_positions
    q2_top1_pct
    q2_top5_pct
    q2_top10_pct
    q2_top20_pct
    q2_hhi
    q2_effective_positions
    architecture_class
  ]

  institutions.each do |x|
    a = x[:q2_arch]

    csv << [
      x[:region],
      x[:country],
      x[:institution],
      x[:cik],
      x[:institution_type],
      x[:q1_filing]&.holdings_value_reported,
      x[:q2_filing]&.holdings_value_reported,
      x[:q1_arch][:positions],
      x[:q2_arch][:positions],
      a[:top1],
      a[:top5],
      a[:top10],
      a[:top20],
      a[:hhi],
      a[:effective_positions],
      architecture_classification(a)
    ]
  end
end

behavior_path = File.join(
  OUTPUT,
  "08_regional_behavior.csv"
)

CSV.open(behavior_path, "w") do |csv|
  csv << behavior_rows.first.keys

  behavior_rows.each do |row|
    csv << row.values
  end
end

security_path = File.join(
  OUTPUT,
  "08_regional_security_alignment.csv"
)

CSV.open(security_path, "w") do |csv|
  csv << security_rows.first.keys

  security_rows.each do |row|
    csv << row.values
  end
end

puts "7. OUTPUT"
puts "---------"
puts summary_path
puts behavior_path
puts security_path
puts
puts "Report complete."
