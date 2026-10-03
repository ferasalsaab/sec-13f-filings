require "csv"
require "yaml"
require "fileutils"

# ============================================================================
# REPORT 07 — SECURITY SIGNALS
#
# Research question:
#   Which securities are experiencing meaningful institutional accumulation
#   or distribution, and what kind of managers are making those decisions?
#
# Principles:
#   - Follow decisions, not dollars.
#   - Manager count alone is insufficient.
#   - Capital importance != signal quality.
#   - Interpretability and mandate context must be preserved.
#   - ADD / REDUCE are cleaner than NEW / EXIT while corporate-action
#     reconciliation remains incomplete.
#   - This report produces research evidence, not buy/sell recommendations.
# ============================================================================

YEAR    = 2026
QUARTER = 2

OUTPUT_DIR = Rails.root.join(
  "research",
  "output",
  "#{YEAR}-Q#{QUARTER}"
)

DETAIL_PATH = OUTPUT_DIR.join("05_manager_behavior_detail.csv")

OVERRIDES_PATH = Rails.root.join(
  "research",
  "cohorts",
  "manager_signal_overrides.yml"
)

OUTPUT_PATH = OUTPUT_DIR.join("07_security_signals.csv")

FileUtils.mkdir_p(OUTPUT_DIR)

unless File.exist?(DETAIL_PATH)
  abort "Missing Report 05 detail file: #{DETAIL_PATH}"
end

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

def normalize_name(name)
  name.to_s.strip.upcase.gsub(/\s+/, " ")
end

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

def parse_number(value)
  return nil if value.nil?
  s = value.to_s.strip
  return nil if s.empty?
  Float(s)
rescue ArgumentError, TypeError
  nil
end

def high_interpretability?(manager)
  manager[:interpretability] == "HIGH"
end

def medium_or_high_interpretability?(manager)
  %w[HIGH MEDIUM].include?(manager[:interpretability])
end

def fundamental_manager?(manager)
  manager[:archetype].to_s.match?(
    /Fundamental|Growth|Foundation|Endowment/i
  )
end

def context_manager?(manager)
  manager[:interpretability] == "LOW"
end

def clean_direction(action)
  case action
  when "ADD"
    :accumulation
  when "REDUCE"
    :distribution
  else
    nil
  end
end

def broad_direction(action)
  case action
  when "ADD", "NEW"
    :accumulation
  when "REDUCE", "EXIT"
    :distribution
  else
    nil
  end
end

def evidence_label(clean_net:, high_net:, fundamental_net:, clean_breadth:)
  # Descriptive evidence taxonomy only.
  # No label is an investment recommendation.

  return "LIMITED_EVIDENCE" if clean_breadth < 2

  # Stronger interpretability layer agrees with broad institutional direction.
  if clean_net > 0 && high_net > 0 && fundamental_net > 0
    return "FUNDAMENTAL_ACCUMULATION"
  end

  if clean_net < 0 && high_net < 0 && fundamental_net < 0
    return "FUNDAMENTAL_DISTRIBUTION"
  end

  # Broad institutions and interpretable/fundamental managers disagree.
  if clean_net > 0 && (high_net < 0 || fundamental_net < 0)
    return "DIVERGENT_BROAD_BUY_FUND_SELL"
  end

  if clean_net < 0 && (high_net > 0 || fundamental_net > 0)
    return "DIVERGENT_BROAD_SELL_FUND_BUY"
  end

  # No broad net direction, but interpretable managers have one.
  if clean_net == 0 && high_net > 0 && fundamental_net > 0
    return "FUNDAMENTAL_ACCUMULATION_BROAD_NEUTRAL"
  end

  if clean_net == 0 && high_net < 0 && fundamental_net < 0
    return "FUNDAMENTAL_DISTRIBUTION_BROAD_NEUTRAL"
  end

  return "BROAD_ACCUMULATION" if clean_net > 0
  return "BROAD_DISTRIBUTION" if clean_net < 0

  "MIXED"
end

# ----------------------------------------------------------------------------
# Load curated manager context
# ----------------------------------------------------------------------------

yaml =
  if File.exist?(OVERRIDES_PATH)
    YAML.load_file(OVERRIDES_PATH) || {}
  else
    {}
  end

manager_context = {}

yaml.fetch("managers", {}).each do |name, attrs|
  manager_context[normalize_name(name)] = {
    archetype: attrs["archetype"] || "UNCLASSIFIED",
    interpretability: attrs["interpretability"] || "UNCLASSIFIED",
    signal_use: attrs["signal_use"] || "UNCLASSIFIED"
  }
end

# ----------------------------------------------------------------------------
# Inspect Report 05 schema
# ----------------------------------------------------------------------------

detail_table = CSV.read(DETAIL_PATH, headers: true)
headers = detail_table.headers

def pick_header(headers, *candidates)
  candidates.find { |candidate| headers.include?(candidate) }
end

manager_col = pick_header(headers, "manager", "manager_name")
cik_col     = pick_header(headers, "cik")
cusip_col   = pick_header(headers, "cusip")
issuer_col  = pick_header(headers, "issuer_name", "issuer")
class_col   = pick_header(headers, "class_title", "class")
action_col  = pick_header(headers, "action")
quality_col = pick_header(
  headers,
  "identity_status",
  "identity_change_status",
  "security_identity_status"
)

q1_value_col = pick_header(
  headers,
  "q1_value",
  "prior_value",
  "previous_value"
)

q2_value_col = pick_header(
  headers,
  "q2_value",
  "current_value"
)

required = {
  manager: manager_col,
  cusip: cusip_col,
  issuer: issuer_col,
  action: action_col
}

missing = required.select { |_k, v| v.nil? }.keys

unless missing.empty?
  puts "Report 05 detail headers:"
  puts headers.inspect
  abort "Missing required columns: #{missing.join(', ')}"
end

# ----------------------------------------------------------------------------
# Aggregate security decisions
#
# Security identity remains CUSIP-led.
# Class title is retained for transparency.
# ----------------------------------------------------------------------------

securities = {}

detail_table.each do |row|
  action = row[action_col].to_s.strip.upcase
  next unless %w[NEW EXIT ADD REDUCE].include?(action)

  identity_status =
    quality_col ? row[quality_col].to_s.strip.upcase : ""

  # Phase-1 corporate-action quarantine from Report 05.
  next if identity_status == "IDENTITY_CHANGE_CANDIDATE"

  manager_name = row[manager_col].to_s
  context =
    manager_context[normalize_name(manager_name)] ||
    {
      archetype: "UNCLASSIFIED",
      interpretability: "UNCLASSIFIED",
      signal_use: "UNCLASSIFIED"
    }

  cusip = row[cusip_col].to_s.strip.upcase
  next if cusip.empty?

  issuer = row[issuer_col].to_s.strip
  class_title = class_col ? row[class_col].to_s.strip : ""

  key = [cusip, class_title.upcase]

  security = securities[key] ||= {
    cusip: cusip,
    issuer: issuer,
    class_title: class_title,
    actions: []
  }

  # Prefer a populated issuer name if an earlier row was blank.
  security[:issuer] = issuer if security[:issuer].to_s.empty? && !issuer.empty?

  security[:actions] << {
    manager: manager_name,
    cik: cik_col ? row[cik_col].to_s : nil,
    action: action,
    archetype: context[:archetype],
    interpretability: context[:interpretability],
    signal_use: context[:signal_use],
    q1_value: q1_value_col ? parse_number(row[q1_value_col]) : nil,
    q2_value: q2_value_col ? parse_number(row[q2_value_col]) : nil
  }
end

# ----------------------------------------------------------------------------
# Build security-level evidence
# ----------------------------------------------------------------------------

rows = securities.values.map do |security|
  actions = security[:actions]

  adds    = actions.select { |a| a[:action] == "ADD" }
  reduces = actions.select { |a| a[:action] == "REDUCE" }
  news    = actions.select { |a| a[:action] == "NEW" }
  exits   = actions.select { |a| a[:action] == "EXIT" }

  clean_actions = adds + reduces

  clean_accumulation = adds.size
  clean_distribution = reduces.size
  clean_net = clean_accumulation - clean_distribution

  high_add = adds.count { |a| high_interpretability?(a) }
  high_reduce = reduces.count { |a| high_interpretability?(a) }
  high_net = high_add - high_reduce

  mh_add = adds.count { |a| medium_or_high_interpretability?(a) }
  mh_reduce = reduces.count { |a| medium_or_high_interpretability?(a) }

  fundamental_add = adds.count { |a| fundamental_manager?(a) }
  fundamental_reduce = reduces.count { |a| fundamental_manager?(a) }
  fundamental_net = fundamental_add - fundamental_reduce

  context_add = adds.count { |a| context_manager?(a) }
  context_reduce = reduces.count { |a| context_manager?(a) }

  archetypes = actions
    .map { |a| a[:archetype] }
    .reject { |x| x == "UNCLASSIFIED" }
    .uniq

  clean_managers = clean_actions.map { |a| a[:manager] }.uniq
  all_managers = actions.map { |a| a[:manager] }.uniq

  clean_breadth = clean_managers.size

  label = evidence_label(
    clean_net: clean_net,
    high_net: high_net,
    fundamental_net: fundamental_net,
    clean_breadth: clean_breadth
  )

  {
    cusip: security[:cusip],
    issuer: security[:issuer],
    class_title: security[:class_title],

    manager_breadth: all_managers.size,
    clean_manager_breadth: clean_breadth,
    archetype_breadth: archetypes.size,

    add_count: adds.size,
    reduce_count: reduces.size,
    new_count: news.size,
    exit_count: exits.size,

    clean_net: clean_net,
    high_add: high_add,
    high_reduce: high_reduce,
    high_net: high_net,

    medium_high_add: mh_add,
    medium_high_reduce: mh_reduce,

    fundamental_add: fundamental_add,
    fundamental_reduce: fundamental_reduce,
    fundamental_net: fundamental_net,

    context_add: context_add,
    context_reduce: context_reduce,

    evidence_label: label,

    accumulation_managers: (adds + news)
      .map { |a| a[:manager] }
      .uniq
      .sort
      .join(" | "),

    distribution_managers: (reduces + exits)
      .map { |a| a[:manager] }
      .uniq
      .sort
      .join(" | "),

    archetypes: archetypes.sort.join(" | ")
  }
end

# Prioritize breadth of CLEAN evidence, then interpretable evidence.
rows.sort_by! do |r|
  [
    -r[:clean_manager_breadth],
    -r[:high_net].abs,
    -r[:fundamental_net].abs,
    -r[:clean_net].abs,
    r[:issuer].to_s
  ]
end

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------

CSV.open(OUTPUT_PATH, "w") do |csv|
  csv << [
    "cusip",
    "issuer",
    "class_title",
    "manager_breadth",
    "clean_manager_breadth",
    "archetype_breadth",
    "add_count",
    "reduce_count",
    "new_count",
    "exit_count",
    "clean_net",
    "high_interpretability_add",
    "high_interpretability_reduce",
    "high_interpretability_net",
    "medium_high_add",
    "medium_high_reduce",
    "fundamental_add",
    "fundamental_reduce",
    "fundamental_net",
    "context_add",
    "context_reduce",
    "evidence_label",
    "accumulation_managers",
    "distribution_managers",
    "archetypes"
  ]

  rows.each do |r|
    csv << [
      r[:cusip],
      r[:issuer],
      r[:class_title],
      r[:manager_breadth],
      r[:clean_manager_breadth],
      r[:archetype_breadth],
      r[:add_count],
      r[:reduce_count],
      r[:new_count],
      r[:exit_count],
      r[:clean_net],
      r[:high_add],
      r[:high_reduce],
      r[:high_net],
      r[:medium_high_add],
      r[:medium_high_reduce],
      r[:fundamental_add],
      r[:fundamental_reduce],
      r[:fundamental_net],
      r[:context_add],
      r[:context_reduce],
      r[:evidence_label],
      r[:accumulation_managers],
      r[:distribution_managers],
      r[:archetypes]
    ]
  end
end

# ----------------------------------------------------------------------------
# Terminal synthesis
# ----------------------------------------------------------------------------

puts
puts "REPORT 07 — SECURITY SIGNALS"
puts "============================"
puts "Portfolio:                  #{YEAR} Q#{QUARTER}"
puts "Securities with decisions:  #{rows.size}"
puts "Manager context entries:    #{manager_context.size}"
puts

puts "EVIDENCE LABELS"
puts "---------------"

rows.group_by { |r| r[:evidence_label] }
    .sort_by { |label, group| [-group.size, label] }
    .each do |label, group|
      puts "#{label.ljust(28)} #{group.size.to_s.rjust(5)}"
    end

def print_security_table(title, rows)
  puts
  puts title
  puts "-" * title.length

  rows.first(15).each do |r|
    puts "#{r[:issuer].to_s[0,28].ljust(28)} " \
         "#{r[:cusip].ljust(9)}  " \
         "A#{r[:add_count].to_s.rjust(2)} " \
         "R#{r[:reduce_count].to_s.rjust(2)}  " \
         "NET #{r[:clean_net].to_s.rjust(3)}  " \
         "HI #{r[:high_net].to_s.rjust(3)}  " \
         "FUND #{r[:fundamental_net].to_s.rjust(3)}  " \
         "#{r[:evidence_label]}"
  end
end

accumulation = rows
  .select { |r| r[:clean_net] > 0 }
  .sort_by do |r|
    [
      -r[:high_net],
      -r[:fundamental_net],
      -r[:clean_net],
      -r[:clean_manager_breadth]
    ]
  end

distribution = rows
  .select { |r| r[:clean_net] < 0 }
  .sort_by do |r|
    [
      r[:high_net],
      r[:fundamental_net],
      r[:clean_net],
      -r[:clean_manager_breadth]
    ]
  end

consensus = rows
  .select { |r| r[:clean_manager_breadth] >= 5 }
  .sort_by do |r|
    [
      -r[:clean_manager_breadth],
      -r[:clean_net].abs,
      -r[:high_net].abs
    ]
  end

print_security_table(
  "INTERPRETABLE ACCUMULATION — TOP 15",
  accumulation
)

print_security_table(
  "INTERPRETABLE DISTRIBUTION — TOP 15",
  distribution
)

print_security_table(
  "BROAD INSTITUTIONAL DECISIONS — TOP 15",
  consensus
)

puts
puts "OUTPUT"
puts "------"
puts OUTPUT_PATH
puts
puts "NOTE"
puts "----"
puts "ADD/REDUCE are treated as cleaner evidence than NEW/EXIT."
puts "NEW/EXIT remain provisional pending fuller corporate-action reconciliation."
puts "Evidence labels describe institutional behavior; they are not investment ratings."
puts "Persistence and subsequent performance are not yet included."
puts
