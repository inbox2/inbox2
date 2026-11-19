# Lore ontology backfill (docs/Ontology.md): mine existing MX mail, newest
# threads first, a bounded batch per run. Deterministic pass always; the LLM
# pass only where the miner allows it (paid org, LLM key) and LORE_LLM != 0.
#
#   bin/rails "lore:backfill[org_xxx,500]"      # one org, newest 500 threads
#   bin/rails "lore:backfill[,200]"             # every org, 200 threads each
#   LORE_LLM=0 bin/rails "lore:backfill[org_xxx,5000]"   # headers only
namespace :lore do
  desc "Mine existing MX conversations into the Lore ontology (bounded batch)"
  task :backfill, %i[org_key limit] => :environment do |_, args|
    limit = (args[:limit].presence || 500).to_i
    use_llm = ENV["LORE_LLM"] != "0"
    orgs = args[:org_key].present? ? Organization.where(key: args[:org_key]) : Organization.all
    orgs.find_each do |org|
      scope = org.conversations.org_readable.where.not(domain_id: nil)
        .where.not(status: Conversation::DISCARDED_STATUSES).order(updated_at: :desc).limit(limit)
      n = 0
      scope.each do |conv|
        LoreMiner.new(conv).call(use_llm: use_llm)
        n += 1
      rescue StandardError => e
        warn "[lore:backfill] #{conv.key}: #{e.class}: #{e.message}"
      end
      puts "[lore:backfill] #{org.key}: #{n} conversations, #{LoreEntity.where(organization: org).count} entities"
    end
  end
end

# Fill the Lore to-do title (docs/Triage.md "Next-action fields") for open
# Lore items that have none: threads summarised before the title existed, and
# re-triaged ones (the re-triage writes no summary). Newest first, plaintext
# only, under the same TriageBreaker caps as triage. Cost: one summary-sized
# OpenAI call (~400 tokens in, ~40 out) per thread.
#
#   bin/rails "lore:titles[org_xxx,200]"
namespace :lore do
  desc "Write next_action_title for open Lore-labelled MX threads lacking one"
  task :titles, %i[org_key limit] => :environment do |_, args|
    org = Organization.find_by!(key: args[:org_key])
    abort "[lore:titles] #{org.key}: AI triage is off for this org" unless org.ai_triage_enabled?
    abort "[lore:titles] no OpenAI key (OPENAI_API_KEY)" unless Llm::Client.default.configured?

    limit = (args[:limit].presence || 200).to_i
    scope = org.conversations.where(status: Conversation::STATUS_OPEN, next_action_title: nil)
               .where.not(triage_label: nil).where.not(triage_label: TriageLabel::NOT_LORE_TODO)
               .order(updated_at: :desc, id: :desc).limit(limit)
    done = throttled = 0
    scope.each do |conv|
      message = ClassifySpaceJob.latest_inbound(conv)
      next if message.nil? || message.sealed?

      breaker = ClassifySpaceJob.breaker_for(org, conv, message)
      unless breaker.allow?
        breaker.record_throttled!
        throttled += 1
        next
      end
      SpaceClassifier.new(org).summarize(conv, message, title_only: true)
      breaker.record_triaged!
      done += 1
    rescue StandardError => e
      warn "[lore:titles] #{conv.key}: #{e.class}: #{e.message}"
    end
    puts "[lore:titles] #{org.key}: #{done} OpenAI calls, #{throttled} throttled"
  end
end
