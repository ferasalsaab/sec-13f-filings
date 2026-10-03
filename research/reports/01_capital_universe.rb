require "csv"
require "fileutils"

year    = (ARGV[0] || ENV["REPORT_YEAR"]).to_i
quarter = (ARGV[1] || ENV["REPORT_QUARTER"]).to_i

abort "Usage: bundle exec rails runner research/reports/01_capital_universe.rb YEAR QUARTER" unless year > 0 && (1..4).include?(quarter)

# 13F filings submitted in the following quarter generally report
# holdings as of the requested portfolio quarter.
filing_year = quarter == 4 ? year + 1 : year
filing_quarter = quarter == 4 ? 1 : quarter + 1

scope = ThirteenF
  .where(filing_year: filing_year, filing_quarter: filing_quarter)
  .where(report_year: year, report_quarter: quarter)
  .where.not(holdings_value_reported: nil)
  .where(restated_by_id: nil)

# One latest usable filing per CIK.
filings = scope
  .order(cik: :asc, date_filed: :desc, id: :desc)
  .to_a
  .uniq(&:cik)

values = filings
  .map { |f| f.holdings_value_reported.to_f }
  .sort

abort "No usable filings found for #{year} Q#{quarter}" if values.empty?

manager_count = values.size
total_value   = values.sum
mean_value    = total_value / manager_count

percentile = lambda do |p|
  return values.first if values.size == 1

  rank  = (p / 100.0) * (values.size - 1)
  lower = values[rank.floor]
  upper = values[rank.ceil]
  lower + (upper - lower) * (rank - rank.floor)
end

median_value = percentile.call(50)

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

percentiles = [1, 5, 10, 25, 50, 75, 80, 90, 95, 99, 99.5, 99.9]

thresholds = [
  500_000,
  1_000_000,
  10_000_000,
  50_000_000,
  75_000_000,
  100_000_000,
  150_000_000,
  250_000_000,
  500_000_000,
  750_000_000,
  1_000_000_000,
  2_000_000_000,
  3_000_000_000,
  5_000_000_000,
  10_000_000_000,
  25_000_000_000,
  50_000_000_000,
  100_000_000_000,
  250_000_000_000,
  500_000_000_000,
  1_000_000_000_000
]

output_dir = Rails.root.join("research", "output", "#{year}-Q#{quarter}")
FileUtils.mkdir_p(output_dir)

summary_path    = output_dir.join("01_capital_universe_summary.csv")
percentile_path = output_dir.join("01_capital_universe_percentiles.csv")
threshold_path  = output_dir.join("01_capital_universe_thresholds.csv")

CSV.open(summary_path, "w") do |csv|
  csv << %w[portfolio_year portfolio_quarter filing_year filing_quarter managers total_reported_13f_value mean_reported_13f_value median_reported_13f_value]
  csv << [
    year,
    quarter,
    filing_year,
    filing_quarter,
    manager_count,
    total_value.round(2),
    mean_value.round(2),
    median_value.round(2)
  ]
end

CSV.open(percentile_path, "w") do |csv|
  csv << %w[percentile reported_13f_value]

  percentiles.each do |p|
    csv << [p, percentile.call(p).round(2)]
  end
end

CSV.open(threshold_path, "w") do |csv|
  csv << %w[threshold managers pct_managers reported_13f_value pct_capital]

  thresholds.each do |threshold|
    selected = filings.select { |f| f.holdings_value_reported.to_f >= threshold }
    selected_value = selected.sum { |f| f.holdings_value_reported.to_f }

    csv << [
      threshold,
      selected.size,
      (selected.size.to_f / manager_count * 100).round(4),
      selected_value.round(2),
      (selected_value / total_value * 100).round(4)
    ]
  end
end

puts
puts "REPORT 01 — CAPITAL UNIVERSE"
puts "============================"
puts "Portfolio period:       #{year} Q#{quarter}"
puts "SEC filing period:      #{filing_year} Q#{filing_quarter}"
puts "Unique managers:        #{manager_count}"
puts "Reported 13F capital:   #{money.call(total_value)}"
puts "Mean portfolio:         #{money.call(mean_value)}"
puts "Median portfolio:       #{money.call(median_value)}"

puts
puts "PORTFOLIO VALUE PERCENTILES"
puts "==========================="

percentiles.each do |p|
  puts "P#{p.to_s.ljust(5)} #{money.call(percentile.call(p))}"
end

puts
puts "SIZE THRESHOLDS"
puts "==============="

puts "#{'THRESHOLD'.ljust(12)} #{'MANAGERS'.rjust(9)} #{'% MGR'.rjust(8)} #{'% CAPITAL'.rjust(10)}"

thresholds.each do |threshold|
  selected = filings.select { |f| f.holdings_value_reported.to_f >= threshold }
  selected_value = selected.sum { |f| f.holdings_value_reported.to_f }

  puts "#{money.call(threshold).ljust(12)} " \
       "#{selected.size.to_s.rjust(9)} " \
       "#{format('%7.2f%%', selected.size.to_f / manager_count * 100)} " \
       "#{format('%9.2f%%', selected_value / total_value * 100)}"
end

zero_count = values.count(&:zero?)

puts
puts "DATA QUALITY"
puts "============"
puts "Zero-value portfolios:  #{zero_count}"
puts "Usable manager records: #{manager_count}"
puts "Deduplication:          latest usable filing per CIK"
puts "Value definition:       reported 13F securities value; NOT total firm AUM"

puts
puts "OUTPUT"
puts "======"
puts summary_path
puts percentile_path
puts threshold_path
puts
