require "csv"
require "fileutils"

year    = (ARGV[0] || ENV["REPORT_YEAR"]).to_i
quarter = (ARGV[1] || ENV["REPORT_QUARTER"]).to_i

abort "Usage: bundle exec rails runner research/reports/04_manager_architecture.rb YEAR QUARTER" unless year > 0 && (1..4).include?(quarter)

filing_year    = quarter == 4 ? year + 1 : year
filing_quarter = quarter == 4 ? 1 : quarter + 1

scope = ThirteenF
  .where(filing_year: filing_year, filing_quarter: filing_quarter)
  .where(report_year: year, report_quarter: quarter)
  .where.not(holdings_value_reported: nil)
  .where(restated_by_id: nil)

filings = scope
  .order(cik: :asc, date_filed: :desc, id: :desc)
  .to_a
  .uniq(&:cik)

abort "No usable filings found for #{year} Q#{quarter}" if filings.empty?

# Report 04 requires detailed holdings to have been materialised locally.
loaded_filings = filings.select { |f| f.holdings.exists? }

abort "No filings with loaded holdings found for #{year} Q#{quarter}" if loaded_filings.empty?

money = lambda do |value|
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

pct = lambda do |numerator, denominator|
  denominator.to_f.zero? ? 0.0 : numerator.to_f / denominator.to_f * 100
end

top_weight = lambda do |values, n, total|
  pct.call(values.first(n).sum, total)
end

rows = loaded_filings.map do |f|
  # Aggregate holdings prevent duplicate raw filing lines from being
  # interpreted as independent portfolio positions.
  #
  # option_type: nil restricts the architecture denominator to
  # long non-option holdings.
  positions = f.aggregate_holdings
    .where(option_type: nil)
    .where("value > 0")
    .order(value: :desc)
    .to_a

  values = positions.map { |h| h.value.to_f }
  long_value = values.sum

  weights =
    if long_value.zero?
      []
    else
      values.map { |value| value / long_value }
    end

  hhi = weights.sum { |weight| weight * weight }
  effective_positions = hhi.zero? ? 0.0 : 1.0 / hhi

  largest = positions.first

  reported_value = f.holdings_value_reported.to_f

  {
    cik: f.cik,
    manager: f.name,
    reported_value: reported_value,
    raw_holdings: f.holdings.count,
    aggregate_holdings: f.aggregate_holdings.count,
    long_value: long_value,
    long_reported_pct: pct.call(long_value, reported_value),
    non_long_reported_value: [reported_value - long_value, 0].max,
    non_long_reported_pct: [100.0 - pct.call(long_value, reported_value), 0].max,
    positions: positions.size,
    top1: top_weight.call(values, 1, long_value),
    top5: top_weight.call(values, 5, long_value),
    top10: top_weight.call(values, 10, long_value),
    top20: top_weight.call(values, 20, long_value),
    hhi: hhi,
    effective_positions: effective_positions,
    largest_issuer: largest&.issuer_name,
    largest_cusip: largest&.cusip,
    largest_value: largest&.value.to_f,
    largest_weight: largest ? pct.call(largest.value, long_value) : 0.0,
    holdings_status: "LOADED"
  }
end

rows.sort_by! { |r| -r[:reported_value] }

output_dir = Rails.root.join("research", "output", "#{year}-Q#{quarter}")
FileUtils.mkdir_p(output_dir)

architecture_path = output_dir.join("04_manager_architecture.csv")

CSV.open(architecture_path, "w") do |csv|
  csv << [
    "cik",
    "manager",
    "reported_13f_value",
    "raw_holdings",
    "aggregate_holdings",
    "long_non_option_value",
    "long_non_option_pct_reported",
    "non_long_reported_value",
    "non_long_reported_pct",
    "long_non_option_positions",
    "top1_pct",
    "top5_pct",
    "top10_pct",
    "top20_pct",
    "hhi",
    "effective_positions",
    "largest_issuer",
    "largest_cusip",
    "largest_position_value",
    "largest_position_weight_pct",
    "holdings_status"
  ]

  rows.each do |r|
    csv << [
      r[:cik],
      r[:manager],
      r[:reported_value].round(2),
      r[:raw_holdings],
      r[:aggregate_holdings],
      r[:long_value].round(2),
      r[:long_reported_pct].round(4),
      r[:non_long_reported_value].round(2),
      r[:non_long_reported_pct].round(4),
      r[:positions],
      r[:top1].round(4),
      r[:top5].round(4),
      r[:top10].round(4),
      r[:top20].round(4),
      r[:hhi].round(8),
      r[:effective_positions].round(2),
      r[:largest_issuer],
      r[:largest_cusip],
      r[:largest_value].round(2),
      r[:largest_weight].round(4),
      r[:holdings_status]
    ]
  end
end

puts
puts "REPORT 04 — MANAGER ARCHITECTURE"
puts "================================"
puts "Portfolio period:       #{year} Q#{quarter}"
puts "Usable filings:         #{filings.size}"
puts "Holdings loaded:        #{loaded_filings.size}"
puts "Architecture coverage:  #{format('%.2f%%', loaded_filings.size.to_f / filings.size * 100)}"

puts
puts "PORTFOLIO ARCHITECTURE"
puts "======================"
puts "#{'MANAGER'.ljust(33)} #{'13F VALUE'.rjust(10)} #{'LONG'.rjust(10)} #{'POS'.rjust(6)} #{'TOP1'.rjust(7)} #{'TOP5'.rjust(7)} #{'TOP10'.rjust(7)} #{'TOP20'.rjust(7)} #{'EFF'.rjust(7)}"

rows.each do |r|
  puts "#{r[:manager].to_s[0,33].ljust(33)} " \
       "#{money.call(r[:reported_value]).rjust(10)} " \
       "#{money.call(r[:long_value]).rjust(10)} " \
       "#{r[:positions].to_s.rjust(6)} " \
       "#{format('%6.1f%%', r[:top1])} " \
       "#{format('%6.1f%%', r[:top5])} " \
       "#{format('%6.1f%%', r[:top10])} " \
       "#{format('%6.1f%%', r[:top20])} " \
       "#{format('%6.1f', r[:effective_positions])}"
end

puts
puts "LONG NON-OPTION / REPORTED VALUE"
puts "================================"
puts "#{'MANAGER'.ljust(43)} #{'% REPORTED'.rjust(11)} #{'RAW'.rjust(8)} #{'AGG'.rjust(8)}"

rows.each do |r|
  puts "#{r[:manager].to_s[0,43].ljust(43)} " \
       "#{format('%10.1f%%', r[:long_reported_pct])} " \
       "#{r[:raw_holdings].to_s.rjust(8)} " \
       "#{r[:aggregate_holdings].to_s.rjust(8)}"
end

puts
puts "MOST CONCENTRATED BY EFFECTIVE POSITIONS"
puts "========================================"

rows.sort_by { |r| r[:effective_positions] }.first(10).each_with_index do |r, index|
  puts "#{(index + 1).to_s.rjust(2)}. " \
       "#{r[:manager].to_s[0,40].ljust(40)} " \
       "#{format('%7.1f', r[:effective_positions])} effective positions | " \
       "Top 10 #{format('%5.1f%%', r[:top10])}"
end

puts
puts "MOST DIVERSIFIED BY EFFECTIVE POSITIONS"
puts "======================================="

rows.sort_by { |r| -r[:effective_positions] }.first(10).each_with_index do |r, index|
  puts "#{(index + 1).to_s.rjust(2)}. " \
       "#{r[:manager].to_s[0,40].ljust(40)} " \
       "#{format('%7.1f', r[:effective_positions])} effective positions | " \
       "Top 10 #{format('%5.1f%%', r[:top10])}"
end

puts
puts "INTERPRETATION"
puts "=============="
puts "Architecture describes the observable 13F portfolio; it does not by itself"
puts "establish investment conviction or manager skill."
puts
puts "Long non-option holdings are used to reduce distortion from reported options."
puts "Market makers, multi-strategy firms, asset owners, passive managers and"
puts "fundamental managers require different interpretive frameworks."
puts
puts "Effective positions = 1 / portfolio HHI. It represents the number of"
puts "equal-weight positions that would produce the observed concentration."

puts
puts "OUTPUT"
puts "======"
puts architecture_path
puts
