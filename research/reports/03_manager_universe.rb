require "csv"
require "fileutils"

year    = (ARGV[0] || ENV["REPORT_YEAR"]).to_i
quarter = (ARGV[1] || ENV["REPORT_QUARTER"]).to_i

abort "Usage: bundle exec rails runner research/reports/03_manager_universe.rb YEAR QUARTER" unless year > 0 && (1..4).include?(quarter)

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
  elsif value >= 1_000
    "$#{format('%.2f', value / 1_000.0)}K"
  else
    "$#{format('%.2f', value)}"
  end
end

research_universe = lambda do |rank, value|
  if rank <= 25
    "Extreme Capital Core"
  elsif rank <= 100
    "Major Capital"
  elsif rank <= 500
    "Core Capital"
  elsif value >= 10_000_000_000
    "Institutional"
  elsif value >= 1_000_000_000
    "Extended"
  else
    "Full"
  end
end

cumulative_value = 0.0

rows = filings.each_with_index.map do |f, index|
  rank = index + 1
  value = f.holdings_value_reported.to_f
  cumulative_value += value

  reported_holdings = f.holdings_count_reported.to_i
  loaded_holdings_count = f.holdings.count
  aggregate_positions = loaded_holdings_count > 0 ? f.aggregate_holdings.count : nil
  holdings_status = loaded_holdings_count > 0 ? "LOADED" : "NOT_LOADED"

  average_position =
    if reported_holdings > 0
      value / reported_holdings
    else
      nil
    end

  # Largest manager receives approximately the 100th size percentile.
  # Smallest manager receives approximately the 0th percentile.
  size_percentile =
    if manager_count == 1
      100.0
    else
      (manager_count - rank).to_f / (manager_count - 1) * 100
    end

  {
    rank: rank,
    cik: f.cik,
    manager: f.name,
    value: value,
    capital_share: total_value.zero? ? 0.0 : value / total_value * 100,
    cumulative_capital_share: total_value.zero? ? 0.0 : cumulative_value / total_value * 100,
    size_percentile: size_percentile,
    reported_holdings: reported_holdings,
    aggregate_positions: aggregate_positions,
    holdings_status: holdings_status,
    average_position: average_position,
    research_universe: research_universe.call(rank, value),
    manager_type: "UNCLASSIFIED",
    active_score: nil,
    interpretability: "UNCLASSIFIED",
    signal_quality: "UNCLASSIFIED"
  }
end

output_dir = Rails.root.join("research", "output", "#{year}-Q#{quarter}")
FileUtils.mkdir_p(output_dir)

master_path = output_dir.join("03_manager_universe.csv")
core_path   = output_dir.join("03_manager_universe_core_500.csv")
top100_path = output_dir.join("03_manager_universe_top_100.csv")
top25_path  = output_dir.join("03_manager_universe_top_25.csv")

headers = [
  "capital_rank",
  "cik",
  "manager",
  "reported_13f_value",
  "capital_share_pct",
  "cumulative_capital_share_pct",
  "size_percentile",
  "reported_holdings",
  "aggregate_positions",
  "holdings_status",
  "average_reported_value_per_holding",
  "research_universe",
  "manager_type",
  "active_score",
  "interpretability",
  "signal_quality"
]

write_rows = lambda do |path, selected_rows|
  CSV.open(path, "w") do |csv|
    csv << headers

    selected_rows.each do |r|
      csv << [
        r[:rank],
        r[:cik],
        r[:manager],
        r[:value].round(2),
        r[:capital_share].round(6),
        r[:cumulative_capital_share].round(6),
        r[:size_percentile].round(4),
        r[:reported_holdings],
        r[:aggregate_positions],
        r[:holdings_status],
        r[:average_position]&.round(2),
        r[:research_universe],
        r[:manager_type],
        r[:active_score],
        r[:interpretability],
        r[:signal_quality]
      ]
    end
  end
end

write_rows.call(master_path, rows)
write_rows.call(core_path, rows.first(500))
write_rows.call(top100_path, rows.first(100))
write_rows.call(top25_path, rows.first(25))

universe_counts = rows.group_by { |r| r[:research_universe] }

puts
puts "REPORT 03 — MANAGER UNIVERSE"
puts "============================"
puts "Portfolio period:       #{year} Q#{quarter}"
puts "Managers:               #{manager_count}"
puts "Reported 13F capital:   #{money.call(total_value)}"

puts
puts "RESEARCH UNIVERSES"
puts "=================="

[
  "Extreme Capital Core",
  "Major Capital",
  "Core Capital",
  "Institutional",
  "Extended",
  "Full"
].each do |label|
  selected = universe_counts.fetch(label, [])
  capital = selected.sum { |r| r[:value] }

  puts "#{label.ljust(23)} " \
       "#{selected.size.to_s.rjust(5)} managers | " \
       "#{format('%6.2f%%', total_value.zero? ? 0 : capital / total_value * 100)} capital | " \
       "#{money.call(capital)}"
end

puts
puts "TOP 25 REPORTING MANAGERS"
puts "========================="
puts "#{'#'.rjust(3)}  #{'MANAGER'.ljust(43)} #{'VALUE'.rjust(10)} #{'% CAP'.rjust(8)} #{'CUM %'.rjust(8)} #{'HOLD'.rjust(7)}"

rows.first(25).each do |r|
  puts "#{r[:rank].to_s.rjust(3)}  " \
       "#{r[:manager].to_s[0,43].ljust(43)} " \
       "#{money.call(r[:value]).rjust(10)} " \
       "#{format('%7.2f%%', r[:capital_share])} " \
       "#{format('%7.2f%%', r[:cumulative_capital_share])} " \
       "#{r[:reported_holdings].to_s.rjust(7)}"
end

puts
puts "CORE-500 COVERAGE"
puts "================="
core_500_capital = rows.first(500).sum { |r| r[:value] }

puts "Managers:               #{[500, manager_count].min}"
puts "Capital represented:    #{money.call(core_500_capital)}"
puts "Share of capital:       #{format('%.2f%%', core_500_capital / total_value * 100)}"

puts
puts "CLASSIFICATION STATUS"
puts "====================="
puts "Manager Type:           UNCLASSIFIED"
puts "Active Score:           pending"
puts "13F Interpretability:   UNCLASSIFIED"
puts "Signal Quality:         UNCLASSIFIED"
puts
puts "These fields are intentionally not inferred from manager names."
puts "They will be populated only after manager taxonomy and portfolio"
puts "architecture/behaviour methodology are validated."

puts
puts "OUTPUT"
puts "======"
puts master_path
puts core_path
puts top100_path
puts top25_path
puts
