require "csv"
require "fileutils"

year    = (ARGV[0] || ENV["REPORT_YEAR"]).to_i
quarter = (ARGV[1] || ENV["REPORT_QUARTER"]).to_i

abort "Usage: bundle exec rails runner research/reports/02_capital_concentration.rb YEAR QUARTER" unless year > 0 && (1..4).include?(quarter)

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
  .sort_by { |f| -f.holdings_value_reported.to_f }

abort "No usable filings found for #{year} Q#{quarter}" if filings.empty?

manager_count = filings.size
total_value   = filings.sum { |f| f.holdings_value_reported.to_f }

money = lambda do |value|
  value = value.to_f

  if value >= 1_000_000_000_000
    "$#{format('%.2f', value / 1_000_000_000_000.0)}T"
  elsif value >= 1_000_000_000
    "$#{format('%.2f', value / 1_000_000_000.0)}B"
  elsif value >= 1_000_000
    "$#{format('%.2f', value / 1_000_000.0)}M"
  else
    "$#{format('%.2f', value)}"
  end
end

# Capital shares by manager.
weights = filings.map do |f|
  total_value.zero? ? 0.0 : f.holdings_value_reported.to_f / total_value
end

hhi = weights.sum { |weight| weight * weight }
effective_managers = hhi.zero? ? 0.0 : 1.0 / hhi

manager_percentages = [0.1, 0.5, 1, 5, 10, 25, 50]

top_pct_rows = manager_percentages.map do |pct|
  count = [(manager_count * pct / 100.0).ceil, 1].max
  selected = filings.first(count)
  capital = selected.sum { |f| f.holdings_value_reported.to_f }

  {
    pct: pct,
    count: count,
    capital: capital,
    capital_pct: total_value.zero? ? 0.0 : capital / total_value * 100
  }
end

coverage_targets = [25, 50, 75, 90, 95, 99]

coverage_rows = coverage_targets.map do |target|
  cumulative = 0.0
  count = 0

  filings.each do |f|
    cumulative += f.holdings_value_reported.to_f
    count += 1
    break if cumulative / total_value * 100 >= target
  end

  {
    target: target,
    count: count,
    manager_pct: count.to_f / manager_count * 100,
    capital: cumulative,
    actual_pct: cumulative / total_value * 100
  }
end

top_n_values = [10, 25, 50, 100, 250, 500, 1000]

top_n_rows = top_n_values
  .select { |n| n <= manager_count }
  .map do |n|
    selected = filings.first(n)
    capital = selected.sum { |f| f.holdings_value_reported.to_f }

    {
      n: n,
      manager_pct: n.to_f / manager_count * 100,
      capital: capital,
      capital_pct: capital / total_value * 100
    }
  end

output_dir = Rails.root.join("research", "output", "#{year}-Q#{quarter}")
FileUtils.mkdir_p(output_dir)

summary_path  = output_dir.join("02_capital_concentration_summary.csv")
top_pct_path  = output_dir.join("02_capital_concentration_top_percent.csv")
coverage_path = output_dir.join("02_capital_concentration_coverage.csv")
top_n_path    = output_dir.join("02_capital_concentration_top_n.csv")

CSV.open(summary_path, "w") do |csv|
  csv << %w[
    portfolio_year
    portfolio_quarter
    managers
    total_reported_13f_value
    hhi
    effective_managers
  ]

  csv << [
    year,
    quarter,
    manager_count,
    total_value.round(2),
    hhi.round(8),
    effective_managers.round(2)
  ]
end

CSV.open(top_pct_path, "w") do |csv|
  csv << %w[
    top_manager_pct
    managers
    reported_13f_value
    pct_capital
  ]

  top_pct_rows.each do |row|
    csv << [
      row[:pct],
      row[:count],
      row[:capital].round(2),
      row[:capital_pct].round(4)
    ]
  end
end

CSV.open(coverage_path, "w") do |csv|
  csv << %w[
    target_capital_pct
    managers_required
    pct_managers
    reported_13f_value
    actual_capital_pct
  ]

  coverage_rows.each do |row|
    csv << [
      row[:target],
      row[:count],
      row[:manager_pct].round(4),
      row[:capital].round(2),
      row[:actual_pct].round(4)
    ]
  end
end

CSV.open(top_n_path, "w") do |csv|
  csv << %w[
    top_n_managers
    pct_managers
    reported_13f_value
    pct_capital
  ]

  top_n_rows.each do |row|
    csv << [
      row[:n],
      row[:manager_pct].round(4),
      row[:capital].round(2),
      row[:capital_pct].round(4)
    ]
  end
end

puts
puts "REPORT 02 — CAPITAL CONCENTRATION"
puts "================================="
puts "Portfolio period:       #{year} Q#{quarter}"
puts "Unique managers:        #{manager_count}"
puts "Reported 13F capital:   #{money.call(total_value)}"
puts "HHI:                    #{format('%.6f', hhi)}"
puts "Effective managers:     #{format('%.1f', effective_managers)}"

puts
puts "CAPITAL CONTROLLED BY TOP MANAGERS"
puts "=================================="
puts "#{'TOP'.ljust(9)} #{'MANAGERS'.rjust(9)} #{'% CAPITAL'.rjust(11)} #{'CAPITAL'.rjust(12)}"

top_pct_rows.each do |row|
  label = "Top #{row[:pct]}%"

  puts "#{label.ljust(9)} " \
       "#{row[:count].to_s.rjust(9)} " \
       "#{format('%10.2f%%', row[:capital_pct])} " \
       "#{money.call(row[:capital]).rjust(12)}"
end

puts
puts "MANAGERS REQUIRED FOR CAPITAL COVERAGE"
puts "======================================"
puts "#{'CAPITAL'.ljust(9)} #{'MANAGERS'.rjust(9)} #{'% MGR'.rjust(9)} #{'ACTUAL'.rjust(9)}"

coverage_rows.each do |row|
  puts "#{("#{row[:target]}%").ljust(9)} " \
       "#{row[:count].to_s.rjust(9)} " \
       "#{format('%8.2f%%', row[:manager_pct])} " \
       "#{format('%8.2f%%', row[:actual_pct])}"
end

puts
puts "TOP-N MANAGER CONCENTRATION"
puts "==========================="
puts "#{'TOP N'.ljust(9)} #{'% MGR'.rjust(9)} #{'% CAPITAL'.rjust(11)} #{'CAPITAL'.rjust(12)}"

top_n_rows.each do |row|
  puts "#{row[:n].to_s.ljust(9)} " \
       "#{format('%8.2f%%', row[:manager_pct])} " \
       "#{format('%10.2f%%', row[:capital_pct])} " \
       "#{money.call(row[:capital]).rjust(12)}"
end

puts
puts "INTERPRETATION NOTE"
puts "==================="
puts "Concentration measures reporting entities, not necessarily independent"
puts "economic institutions. Related reporting entities may belong to the same"
puts "parent organisation. Reported 13F value is not total firm AUM."

puts
puts "OUTPUT"
puts "======"
puts summary_path
puts top_pct_path
puts coverage_path
puts top_n_path
puts
