#!/usr/bin/env ruby
# frozen_string_literal: true

# Triage worker for SEALED mail (docs/E2EE.md Phase E).
#
# Consumes plaintext excerpts from the MEMORY-backed TRIAGE_INBOUND stream (the
# transient surface the Go MX publishes to at seal time), classifies them via
# the configured ClassificationProviders adapter (Jev), and writes back ONLY
# low-information metadata (space_id, triage label/priority/source) onto the
# already-sealed row — never a summary (docs/E2EE.md "Output rule"). The excerpt body
# exists in this process's RAM for the duration of one classification call and
# is never persisted anywhere.
#
# Failure semantics (docs/E2EE.md "Failure & backpressure"):
#   • sealed row not yet written (consumer race) → nak, redeliver with backoff;
#     if the row never appears before the stream TTL, the excerpt ages out and
#     the message simply stays unlabeled — the seal already stands.
#   • provider down/slow → nak + backoff, same TTL bound. Mail storage never
#     depends on this worker.
#
# Usage:
#   bundle exec ruby lib/triage_subscriber.rb

require_relative "../config/environment"
require "nats/client"
require "json"

class TriageSubscriber
  STREAM_NAME = "TRIAGE_INBOUND" unless defined?(STREAM_NAME)
  CONSUMER_NAME = "RAILS_TRIAGE_WORKER" unless defined?(CONSUMER_NAME)
  SUBJECT = "triage.inbound.>" unless defined?(SUBJECT)

  def initialize
    @running = true
    @nats_config = load_nats_config
  end

  def run
    setup_signal_handlers
    connect
    setup_consumer
    consume_loop
    @nats&.drain
    @nats&.close
    Rails.logger.info("[TriageSubscriber] Stopped")
  end

  # Processes one excerpt. Returns :ack or :nak — split out for direct testing.
  def handle_excerpt(payload)
    org = Organization.find_by(id: payload["org_id"])
    return :ack unless org # org deleted — nothing to label

    msgid_hmac = payload["msgid_hmac"].to_s
    return :ack if msgid_hmac.blank? # uncorrelatable (no Message-ID at seal time)

    message = org.messages.shared.find_by(msgid_hmac: msgid_hmac)
    # The durable consumer may not have written the sealed row yet — redeliver
    # until it appears or the memory stream expires the excerpt.
    return :nak unless message

    conversation = message.conversation
    # Rspamd flagged it at ingest (the MX-inline verdict rides the sealed row) —
    # spam is never triaged, mirroring ClassifySpaceJob#triage.
    # Ordering is safe: the nak-until-row-exists loop above means the status is
    # already authoritative by the time we get here.
    return :ack unless conversation.status == Conversation::STATUS_OPEN

    # Same plan gate as the plaintext lane (defence-in-depth on top of the
    # MX-side entitlement resolution).
    return :ack unless org.ai_triage_enabled?

    provider = ClassificationProviders.default
    return :ack unless provider.configured? # never labeled; seal stands

    # Every sealed message re-runs label + priority; the space is only chosen
    # while the thread has none (replies inherit).
    domain = org.domains.find_by(id: payload["domain_id"])
    breaker = TriageBreaker.new(org, domain: domain)
    SpaceClassifier.new(org, provider: provider, breaker: breaker).classify_excerpt(
      conversation,
      subject: payload["subject"], from: payload["from"], to: payload["to"], excerpt: payload["excerpt"]
    )
    :ack
  rescue => e
    # Includes Jev::Client::TransientError: nak, redeliver within the TTL.
    Rails.logger.error("[TriageSubscriber] classify error: #{e.message}")
    :nak
  end

  private

  def load_nats_config
    config_path = Rails.root.join("config", "nats.yml")
    config = YAML.safe_load(ERB.new(File.read(config_path)).result, aliases: true)
    config.fetch(Rails.env, config.fetch("default", {}))
  end

  def connect
    @nats = NATS.connect(@nats_config["url"])
    @js = @nats.jetstream
    ensure_stream
    Rails.logger.info("[TriageSubscriber] Connected to #{@nats_config['url']}")
  end

  # The Go MX normally creates the stream; create it here only if absent (same
  # config — MEMORY storage, limits retention, short TTL) so worker-first boot
  # order works in dev.
  def ensure_stream
    @js.find_stream_name_by_subject(SUBJECT)
  rescue NATS::JetStream::Error::NotFound
    @js.add_stream(
      name: STREAM_NAME,
      subjects: [SUBJECT],
      retention: "limits",
      max_age: 10 * 60 * 1_000_000_000, # 10m in ns — the transient plaintext bound
      max_bytes: 256 * 1024 * 1024,
      storage: "memory",
      discard: "old"
    )
    Rails.logger.info("[TriageSubscriber] Created stream #{STREAM_NAME}")
  end

  def setup_consumer
    begin
      @js.consumer_info(STREAM_NAME, CONSUMER_NAME)
    rescue NATS::JetStream::Error::NotFound
      @js.add_consumer(STREAM_NAME, {
        durable_name: CONSUMER_NAME,
        filter_subject: SUBJECT,
        ack_policy: "explicit",
        ack_wait: 30,
        # Enough redeliveries to outlast a short provider outage or the
        # row-not-yet-written race, bounded well inside the 10m stream TTL.
        max_deliver: 15,
        max_ack_pending: 50
      })
    end

    @psub = @js.pull_subscribe(SUBJECT, CONSUMER_NAME, stream: STREAM_NAME)
    Rails.logger.info("[TriageSubscriber] Consumer active on #{STREAM_NAME}/#{CONSUMER_NAME}")
  end

  def consume_loop
    while @running
      begin
        msgs = @psub.fetch(5, timeout: 5)
        msgs.each { |msg| process(msg) }
      rescue NATS::IO::Timeout
        # No excerpts pending
      rescue => e
        Rails.logger.error("[TriageSubscriber] Consume error: #{e.message}")
        sleep 1
      end
    end
  end

  def process(msg)
    payload = JSON.parse(msg.data)
    if handle_excerpt(payload) == :ack
      msg.ack
    else
      msg.nak
    end
  rescue JSON::ParserError => e
    Rails.logger.error("[TriageSubscriber] Bad excerpt payload: #{e.message}")
    msg.ack # malformed — redelivery can't fix it
  end

  def setup_signal_handlers
    %w[INT TERM].each do |signal|
      Signal.trap(signal) { @running = false }
    end
  end
end

TriageSubscriber.new.run if __FILE__ == $PROGRAM_NAME
