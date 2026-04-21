require "process"

# Run all pattern benchmarks sequentially, appending to bench/results.jsonl.
# All patterns share one RUN_ID so `bench/report.cr` can compare across them.

run_id = ENV["OMQ_BENCH_RUN_ID"]? || Time.local.to_s("%Y-%m-%dT%H:%M:%S")
ENV["OMQ_BENCH_RUN_ID"] = run_id

patterns = %w[push_pull pub_sub req_rep router_dealer pair]

patterns.each do |pattern|
  source = File.join(__DIR__, pattern, "omq.cr")
  args = %w[run --release --no-debug] + [source]
  puts "\n=== #{pattern} ===\n"
  status = Process.run("crystal", args, input: Process::Redirect::Inherit,
    output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
  abort "#{pattern} failed (exit #{status.exit_code})" unless status.success?
end
