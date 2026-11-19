require "benchmark"

namespace :mailbox_graph do
  desc "Benchmark mailbox graph computation: naive vs precomputed snapshot"
  task benchmark: :environment do
    org = Organization.first
    abort "No organization found. Run `rails db:seed` first." unless org

    conv_count = org.conversations.count
    puts "\n═══════════════════════════════════════════════════════"
    puts "  Mailbox Network Graph — Benchmark"
    puts "═══════════════════════════════════════════════════════"
    puts "  Organization: #{org.name} (#{org.default_domain&.name})"
    puts "  Conversations: #{conv_count}"
    puts "  Mailboxes: #{org.conversations.where.not(to_address: [nil, '']).distinct.count(:to_address)}"
    puts ""

    # ── Warm up ──
    puts "  Warming up..."
    aggregator = MailboxGraphAggregator.new(org)
    aggregator.call
    puts ""

    # ── A) Naive request-time recomputation ──
    iterations = 20
    naive_times = []
    puts "  (A) Naive request-time aggregation (#{iterations} runs)..."

    iterations.times do
      t = Benchmark.realtime { MailboxGraphAggregator.new(org).call }
      naive_times << (t * 1000) # ms
    end

    naive_times.sort!
    p50_naive = naive_times[naive_times.length / 2]
    p95_naive = naive_times[(naive_times.length * 0.95).to_i]
    p99_naive = naive_times[(naive_times.length * 0.99).to_i]

    # ── B) Refresh job (compute + upsert) ──
    puts "  (B) Refresh job wall time..."
    # Clear existing snapshot
    org.mailbox_graph_snapshot&.destroy

    refresh_times = []
    5.times do
      org.reload
      org.mailbox_graph_snapshot&.destroy
      t = Benchmark.realtime { RefreshMailboxGraphJob.new.perform(org.id) }
      refresh_times << (t * 1000)
    end
    refresh_times.sort!
    refresh_median = refresh_times[refresh_times.length / 2]

    # ── C) Precomputed snapshot read ──
    puts "  (C) Precomputed snapshot read (#{iterations} runs)..."
    # Ensure snapshot exists
    RefreshMailboxGraphJob.new.perform(org.id)

    read_times = []
    iterations.times do
      t = Benchmark.realtime {
        snapshot = org.reload.mailbox_graph_snapshot
        # Simulate what the controller does: serialize
        MailboxGraphSnapshotSerializer.new(snapshot).to_h
      }
      read_times << (t * 1000)
    end

    read_times.sort!
    p50_read = read_times[read_times.length / 2]
    p95_read = read_times[(read_times.length * 0.95).to_i]
    p99_read = read_times[(read_times.length * 0.99).to_i]

    # ── Results ──
    puts ""
    puts "  ┌─────────────────────────┬───────────┬───────────┬───────────┐"
    puts "  │                         │   p50     │   p95     │   p99     │"
    puts "  ├─────────────────────────┼───────────┼───────────┼───────────┤"
    puts format("  │ (A) Naive aggregation   │ %7.2fms │ %7.2fms │ %7.2fms │", p50_naive, p95_naive, p99_naive)
    puts format("  │ (C) Snapshot read        │ %7.2fms │ %7.2fms │ %7.2fms │", p50_read, p95_read, p99_read)
    puts "  └─────────────────────────┴───────────┴───────────┴───────────┘"
    puts ""
    puts format("  (B) Refresh job median: %.2fms", refresh_median)
    puts format("  Speedup (p50): %.1fx", p50_naive / [p50_read, 0.01].max)
    puts ""
    puts "  Dataset: #{conv_count} conversations"
    puts "  Note: Load the Enron corpus (`rake datasets:load[enron]`) for"
    puts "  a more realistic benchmark with ~500K messages."
    puts "═══════════════════════════════════════════════════════\n\n"
  end
end
