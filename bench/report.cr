require "json"
require "option_parser"

# Regression report. Reads bench/results.jsonl, compares the last N runs
# of matching keys, flags >threshold% regressions/improvements.
#
# Usage:
#   crystal run bench/report.cr
#   crystal run bench/report.cr -- --runs 5 --threshold 10 --pattern push_pull

RESULTS_PATH = File.expand_path("results.jsonl", __DIR__)

runs_window = 2
threshold = 5.0
pattern_filter : String? = nil
show_all = false
update_readme = false

OptionParser.parse do |p|
  p.banner = "Usage: crystal run bench/report.cr -- [options]"
  p.on("--runs N", "Number of runs to compare (default 2)") { |v| runs_window = v.to_i }
  p.on("--threshold PCT", "Noise band percentage (default 5)") { |v| threshold = v.to_f }
  p.on("--pattern NAME", "Filter to one pattern") { |v| pattern_filter = v }
  p.on("--all", "Show every measurement, not just outliers") { show_all = true }
  p.on("--update-readme", "Regenerate bench/README.md tables") { update_readme = true }
  p.on("-h", "--help", "Show this help") { puts p; exit 0 }
end

abort "No results file at #{RESULTS_PATH}. Run benchmarks first." unless File.exists?(RESULTS_PATH)

record Row, run_id : String, pattern : String, transport : String,
  peers : Int32, msg_size : Int32, msg_count : Int64,
  elapsed_s : Float64, mbps : Float64, msgs_s : Float64

rows = [] of Row
File.each_line(RESULTS_PATH) do |line|
  next if line.strip.empty?
  j = JSON.parse(line)
  rows << Row.new(
    run_id: j["run_id"].as_s,
    pattern: j["pattern"].as_s,
    transport: j["transport"].as_s,
    peers: j["peers"].as_i,
    msg_size: j["msg_size"].as_i,
    msg_count: j["msg_count"].as_i64,
    elapsed_s: j["elapsed_s"].as_f,
    mbps: j["mbps"].as_f,
    msgs_s: j["msgs_s"].as_f,
  )
end

if update_readme
  readme_path = File.expand_path("README.md", __DIR__)
  transports  = %w[inproc ipc tcp]
  size_labels = {128 => "128 B", 512 => "512 B", 2048 => "2 KiB", 8192 => "8 KiB", 32768 => "32 KiB"}

  abort "No runs found in #{RESULTS_PATH}" if rows.empty?

  # Most recent row per (pattern, transport, peers, msg_size) across all
  # history. Falling back lets partial reruns refresh just the cells
  # they cover instead of clobbering untouched cells with "—".
  cell = ->(pattern : String, transport : String, peers : Int32, msg_size : Int32) do
    rows.reverse_each.find do |r|
      r.pattern == pattern && r.transport == transport &&
        r.peers == peers && r.msg_size == msg_size
    end
  end

  fmt_rate = ->(v : Float64) : String do
    if v >= 1e6
      sprintf("%.2fM msg/s", v / 1e6)
    elsif v >= 1e3
      sprintf("%.1fk msg/s", v / 1e3)
    else
      sprintf("%.0f msg/s", v)
    end
  end

  # Trailing * flags a nominal figure: payloads are shared (not `.dup`'d),
  # so the sender and receiver operate on the same `Bytes` pointer. For
  # inproc that means no memory copy happens at all — the product
  # (msg/s × size) overstates actual memory bandwidth. For IPC/TCP the
  # kernel still copies the bytes, but we apply the same asterisk for
  # consistency since the benchmark never attributes bytes to per-message
  # allocator work.
  fmt_mbps = ->(v : Float64) : String do
    unit = if v >= 1000
             sprintf("%.2f GB/s*", v / 1000.0)
           elsif v >= 100
             sprintf("%.0f MB/s*", v)
           elsif v >= 10
             sprintf("%.1f MB/s*", v)
           else
             sprintf("%.2f MB/s*", v)
           end
    unit
  end

  fmt_throughput = ->(r : Row?) : String do
    r.nil? ? "—" : "#{fmt_rate.call(r.msgs_s)} / #{fmt_mbps.call(r.mbps)}"
  end

  fmt_latency_us = ->(r : Row?) : String do
    if r.nil? || r.msgs_s <= 0
      "—"
    else
      us = 1_000_000.0 / r.msgs_s
      if us >= 100
        sprintf("%.0f µs", us)
      elsif us >= 10
        sprintf("%.1f µs", us)
      else
        sprintf("%.2f µs", us)
      end
    end
  end

  build_throughput_table = ->(pattern : String, peer_counts : Array(Int32)) do
    String.build do |io|
      io << "\n"
      peer_counts.each do |peers|
        sizes = size_labels.keys
        any = sizes.any? { |s| transports.any? { |t| cell.call(pattern, t, peers, s) } }
        next unless any
        io << "### #{peers} peer#{"s" if peers > 1}\n\n"
        io << "| Message size | #{transports.join(" | ")} |\n"
        io << "|---|#{transports.map { "---" }.join("|")}|\n"
        sizes.each do |size|
          values = transports.map { |t| fmt_throughput.call(cell.call(pattern, t, peers, size)) }
          io << "| #{size_labels[size]} | #{values.join(" | ")} |\n"
        end
        io << "\n"
      end
    end
  end

  build_latency_table = ->(pattern : String) do
    String.build do |io|
      io << "\n| Message size | #{transports.join(" | ")} |\n"
      io << "|---|#{transports.map { "---" }.join("|")}|\n"
      size_labels.keys.each do |size|
        values = transports.map { |t| fmt_latency_us.call(cell.call(pattern, t, 1, size)) }
        io << "| #{size_labels[size]} | #{values.join(" | ")} |\n"
      end
      io << "\n"
    end
  end

  replace_block = ->(text : String, marker : String, new_content : String) do
    begin_tag = "<!-- BEGIN #{marker} -->"
    end_tag = "<!-- END #{marker} -->"
    re = /#{Regex.escape(begin_tag)}.*?#{Regex.escape(end_tag)}/m
    abort "marker #{begin_tag} not found in README" unless text.matches?(re)
    text.sub(re, "#{begin_tag}#{new_content}#{end_tag}")
  end

  readme = File.read(readme_path)
  readme = replace_block.call(readme, "push_pull",     build_throughput_table.call("push_pull",     [1, 3]))
  readme = replace_block.call(readme, "req_rep",       build_latency_table.call("req_rep"))
  readme = replace_block.call(readme, "router_dealer", build_throughput_table.call("router_dealer", [3]))
  readme = replace_block.call(readme, "pub_sub",       build_throughput_table.call("pub_sub",       [3]))
  readme = replace_block.call(readme, "pair",          build_throughput_table.call("pair",          [1]))
  File.write(readme_path, readme)
  puts "Updated #{readme_path} (#{rows.map(&.run_id).uniq.size} run(s) in history)"
  exit 0
end

if pattern = pattern_filter
  rows.select! { |r| r.pattern == pattern }
end

run_ids = rows.map(&.run_id).uniq.last(runs_window)
abort "Need at least 2 runs to compare, found #{run_ids.size}." if run_ids.size < 2

alias Key = Tuple(String, String, Int32, Int32)
by_key = {} of Key => Hash(String, Row)
rows.each do |r|
  next unless run_ids.includes?(r.run_id)
  key = {r.pattern, r.transport, r.peers, r.msg_size}
  by_key.put_if_absent(key) { {} of String => Row }
  by_key[key][r.run_id] = r
end

RED    = "\e[31m"
GREEN  = "\e[32m"
YELLOW = "\e[33m"
DIM    = "\e[2m"
BOLD   = "\e[1m"
RESET  = "\e[0m"

def format_si(value : Float64) : String
  if value >= 1e9
    sprintf("%.1fG", value / 1e9)
  elsif value >= 1e6
    sprintf("%.1fM", value / 1e6)
  elsif value >= 1e3
    sprintf("%.1fk", value / 1e3)
  else
    sprintf("%.0f", value)
  end
end

def format_mbps(value : Float64) : String
  if value >= 1_000_000
    sprintf("%.1f TB/s", value / 1_000_000)
  elsif value >= 1_000
    sprintf("%.1f GB/s", value / 1_000)
  else
    sprintf("%.1f MB/s", value)
  end
end

def format_size(bytes : Int32) : String
  bytes >= 1024 ? "#{bytes // 1024}KB" : "#{bytes}B"
end

base_run = run_ids.first
latest_run = run_ids.last
regressions = [] of NamedTuple(pattern: String, transport: String, peers: String, size: String, metric: Symbol, old: String, new: String, delta: Float64)
improvements = [] of typeof(regressions.first)
stable_count = 0

by_key.to_a.sort_by(&.[0]).each do |(key, runs)|
  base = runs[base_run]?
  latest = runs[latest_run]?
  next unless base && latest

  pattern, transport, peers, msg_size = key
  peer_label = "#{peers} peer#{"s" if peers > 1}"

  {:msgs_s, :mbps}.each do |metric|
    if metric == :msgs_s
      old_val, new_val = base.msgs_s, latest.msgs_s
    else
      old_val, new_val = base.mbps, latest.mbps
    end
    next if old_val.zero?

    delta = ((new_val - old_val) / old_val * 100).round(1)
    if metric == :msgs_s
      formatted_old, formatted_new = format_si(old_val), format_si(new_val)
    else
      formatted_old, formatted_new = format_mbps(old_val), format_mbps(new_val)
    end
    row = {
      pattern: pattern, transport: transport, peers: peer_label,
      size: format_size(msg_size), metric: metric,
      old: formatted_old, new: formatted_new, delta: delta,
    }

    if delta <= -threshold
      regressions << row
    elsif delta >= threshold
      improvements << row
    else
      stable_count += 1
    end
  end
end

total = regressions.size + improvements.size + stable_count
span = run_ids.size == 2 ? "#{latest_run} vs #{base_run}" : "#{latest_run} vs #{base_run} (#{run_ids.size} runs)"
puts "#{BOLD}=== OMQ Benchmark Report (#{span}) ===#{RESET}"
puts

if regressions.any?
  puts "#{RED}#{BOLD}REGRESSIONS (>#{threshold}%):#{RESET}"
  regressions.each do |r|
    printf "  %-15s %-8s %-9s %5s  %-6s  %10s → %-10s  #{RED}%+.1f%%#{RESET}\n",
      r[:pattern], r[:transport], r[:peers], r[:size], r[:metric], r[:old], r[:new], r[:delta]
  end
  puts
end

if improvements.any?
  puts "#{GREEN}#{BOLD}IMPROVEMENTS (>#{threshold}%):#{RESET}"
  improvements.each do |r|
    printf "  %-15s %-8s %-9s %5s  %-6s  %10s → %-10s  #{GREEN}%+.1f%%#{RESET}\n",
      r[:pattern], r[:transport], r[:peers], r[:size], r[:metric], r[:old], r[:new], r[:delta]
  end
  puts
end

if regressions.empty? && improvements.empty?
  puts "#{DIM}All #{total} measurements stable (±#{threshold}%)#{RESET}"
else
  puts "#{DIM}#{total} measurements: #{regressions.size} regressions, #{improvements.size} improvements, #{stable_count} stable (±#{threshold}%)#{RESET}"
end

if show_all
  puts
  puts "#{BOLD}=== Full Results ===#{RESET}"
  by_key.to_a.sort_by(&.[0]).each do |(key, runs)|
    pattern, transport, peers, msg_size = key
    peer_label = "#{peers} peer#{"s" if peers > 1}"
    printf "\n  %-15s %-8s %-9s %5s", pattern, transport, peer_label, format_size(msg_size)

    {:msgs_s, :mbps}.each do |metric|
      printf "  %-6s", metric
      values = run_ids.map do |id|
        r = runs[id]?
        next nil unless r
        metric == :msgs_s ? r.msgs_s : r.mbps
      end
      values.each do |v|
        printf "  %10s", v.nil? ? "--" : (metric == :msgs_s ? format_si(v) : format_mbps(v))
      end
    end
  end
  puts
  puts
end
