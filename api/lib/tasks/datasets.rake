require "mail"

namespace :datasets do
  LOADERS = {
    "enron" => "Datasets::Enron",
    "spamassassin" => "Datasets::SpamAssassin"
  }.freeze

  def load_dataset_classes
    require_relative "../datasets/base"
    require_relative "../datasets/enron"
    require_relative "../datasets/spam_assassin"
  end

  def resolve_org
    org = Organization.first
    abort "No organization found. Run `rails db:seed` first." unless org
    org
  end

  desc "List available email datasets"
  task list: :environment do
    load_dataset_classes
    puts "\nAvailable datasets:\n\n"
    puts format("  %-18s %-35s %10s   %s", "SLUG", "NAME", "~EMAILS", "DESCRIPTION")
    puts "  " + "-" * 100
    LOADERS.each do |slug, klass_name|
      klass = klass_name.constantize
      puts format("  %-18s %-35s %10s   %s",
        klass.slug,
        klass.display_name,
        number_with_delimiter(klass.approximate_count),
        klass.description.truncate(60))
    end
    puts "\nUsage:"
    puts "  rake datasets:load[enron]              # Load full Enron corpus (~500K emails)"
    puts "  rake datasets:load[enron,1000]          # Load first 1,000 conversations"
    puts "  rake datasets:load[spamassassin]        # Load SpamAssassin corpus"
    puts "  rake datasets:load_all                  # Load all datasets"
    puts "  rake datasets:stats                     # Show import stats"
    puts "  rake datasets:purge[enron]              # Remove a dataset's conversations"
    puts "  rake datasets:purge_all                 # Remove all dataset conversations"
    puts ""
  end

  desc "Load an email dataset. Usage: rake datasets:load[name,limit]"
  task :load, [ :name, :limit ] => :environment do |_t, args|
    load_dataset_classes
    name = args[:name]
    limit = args[:limit]&.to_i

    abort "Dataset name required. Run `rake datasets:list` to see options." unless name
    klass_name = LOADERS[name]
    abort "Unknown dataset '#{name}'. Run `rake datasets:list` to see options." unless klass_name

    org = resolve_org
    klass = klass_name.constantize
    loader = klass.new(organization: org, limit: limit)

    puts "\n=== Loading #{klass.display_name} ==="
    puts "  Organization: #{org.name} (#{org.default_domain&.name})"
    puts "  Limit: #{limit || 'none (full corpus)'}"
    puts ""

    started = Time.now
    loader.load!
    elapsed = Time.now - started

    puts "\n  Completed in #{format_duration(elapsed)}"
  end

  desc "Load all available datasets"
  task :load_all, [ :limit ] => :environment do |_t, args|
    load_dataset_classes
    limit = args[:limit]&.to_i
    org = resolve_org

    LOADERS.each do |name, klass_name|
      klass = klass_name.constantize
      puts "\n=== Loading #{klass.display_name} ==="
      loader = klass.new(organization: org, limit: limit)
      started = Time.now
      loader.load!
      elapsed = Time.now - started
      puts "  Completed in #{format_duration(elapsed)}\n"
    end
  end

  desc "Show dataset import statistics"
  task stats: :environment do
    load_dataset_classes
    org = resolve_org

    puts "\nDataset import statistics for #{org.name}:\n\n"
    puts format("  %-18s %12s %12s", "DATASET", "CONVERSATIONS", "MESSAGES")
    puts "  " + "-" * 46
    total_convs = 0
    total_msgs = 0

    LOADERS.each do |slug, _klass_name|
      convs = Conversation.where(organization: org)
        .where("subject LIKE ?", "[#{slug}]%")
        .count
      msgs = Message.where(organization: org)
        .joins(:conversation)
        .where("conversations.subject LIKE ?", "[#{slug}]%")
        .count
      puts format("  %-18s %12s %12s", slug, number_with_delimiter(convs), number_with_delimiter(msgs))
      total_convs += convs
      total_msgs += msgs
    end

    # Seed data (non-dataset)
    seed_convs = Conversation.where(organization: org).count - total_convs
    seed_msgs = Message.where(organization: org).count - total_msgs
    puts format("  %-18s %12s %12s", "(seed data)", number_with_delimiter(seed_convs), number_with_delimiter(seed_msgs))

    puts "  " + "-" * 46
    all_convs = Conversation.where(organization: org).count
    all_msgs = Message.where(organization: org).count
    puts format("  %-18s %12s %12s", "TOTAL", number_with_delimiter(all_convs), number_with_delimiter(all_msgs))
    puts ""
  end

  desc "Purge a dataset's conversations. Usage: rake datasets:purge[name]"
  task :purge, [ :name ] => :environment do |_t, args|
    load_dataset_classes
    name = args[:name]
    abort "Dataset name required." unless name
    abort "Unknown dataset '#{name}'." unless LOADERS[name]

    org = resolve_org
    klass = LOADERS[name].constantize
    loader = klass.new(organization: org)
    loader.purge!
  end

  desc "Purge all dataset conversations (keeps seed data)"
  task purge_all: :environment do
    load_dataset_classes
    org = resolve_org

    LOADERS.each do |name, klass_name|
      klass = klass_name.constantize
      loader = klass.new(organization: org)
      loader.purge!
    end
  end

  def number_with_delimiter(n)
    n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
  end

  def format_duration(seconds)
    if seconds < 60
      "#{seconds.round(1)}s"
    elsif seconds < 3600
      mins = (seconds / 60).floor
      secs = (seconds % 60).round(0)
      "#{mins}m #{secs}s"
    else
      hrs = (seconds / 3600).floor
      mins = ((seconds % 3600) / 60).round(0)
      "#{hrs}h #{mins}m"
    end
  end
end
