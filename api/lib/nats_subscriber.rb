#!/usr/bin/env ruby
# frozen_string_literal: true

# NATS subscriber process for the inbound mail pipeline (spec 16.1.1, 16.2.3).
#
# Responsibilities:
#   1. Domain lookup responder — answers MX server's domain validation requests
#   2. Inbound message consumer — processes accepted mail from JetStream
#
# Usage:
#   bundle exec ruby lib/nats_subscriber.rb

require_relative "../config/environment"
require "nats/client"
require "json"

class NatsSubscriber
  # Guarded so the file is safe to load twice (Rails eager-loads the class,
  # then `ruby lib/nats_subscriber.rb` defines it again) without const warnings.
  STREAM_NAME = "MAIL_INBOUND" unless defined?(STREAM_NAME)
  CONSUMER_NAME = "RAILS_INBOUND_PROCESSOR" unless defined?(CONSUMER_NAME)
  DOMAIN_LOOKUP_SUBJECT = "inbox2.domain.lookup" unless defined?(DOMAIN_LOOKUP_SUBJECT)
  INBOUND_SUBJECT = "mail.inbound.>" unless defined?(INBOUND_SUBJECT)

  STATUS_STREAM_NAME = "MAIL_DELIVERY_STATUS" unless defined?(STATUS_STREAM_NAME)
  STATUS_CONSUMER_NAME = "RAILS_DELIVERY_STATUS" unless defined?(STATUS_CONSUMER_NAME)
  STATUS_SUBJECT = "mail.delivery.status.>" unless defined?(STATUS_SUBJECT)

  def initialize
    @running = true
    @nats_config = load_nats_config
  end

  def run
    setup_signal_handlers
    connect
    setup_domain_responder
    setup_inbound_consumer
    setup_delivery_status_consumer
    wait
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
    Rails.logger.info("[NatsSubscriber] Connected to #{@nats_config['url']}")
  end

  def ensure_stream
    @js.find_stream_name_by_subject("mail.inbound.>")
  rescue NATS::JetStream::Error::NotFound
    @js.add_stream(
      name: STREAM_NAME,
      subjects: [INBOUND_SUBJECT],
      retention: "workqueue",
      max_age: 72 * 3600 * 1_000_000_000, # 72h in nanoseconds
      max_bytes: 10 * 1024 * 1024 * 1024,  # 10GB
      storage: "file",
      discard: "old"
    )
    Rails.logger.info("[NatsSubscriber] Created stream #{STREAM_NAME}")
  end

  def setup_domain_responder
    @nats.subscribe(DOMAIN_LOOKUP_SUBJECT) do |msg|
      handle_domain_lookup(msg)
    end
    Rails.logger.info("[NatsSubscriber] Domain responder active on #{DOMAIN_LOOKUP_SUBJECT}")
  end

  def handle_domain_lookup(msg)
    request = JSON.parse(msg.data)
    domain = request["domain"]&.downcase&.strip
    return msg.respond(JSON.generate({ found: false })) if domain.blank?

    # The ESP's bounce domain belongs to no org: mail to it is delivery reports
    # for API sends (Esp::BounceProcessor).
    if domain == Esp::BOUNCE_DOMAIN
      return msg.respond(JSON.generate({ found: true, org_id: 0, org_key: "esp", status: Domain::STATUS_RECEIVING_MAIL,
        max_message_size_mb: 10, e2ee: false }))
    end

    domain_record = Domain.find_by(name: domain)

    # A billing-locked domain (over a downgraded plan's limit) stops receiving
    # mail — report it as not found so the MX server rejects.
    if domain_record.nil? || domain_record.locked?
      msg.respond(JSON.generate({ found: false }))
    else
      org = domain_record.organization
      # Effective plan (per-org override → subscription → Free) drives the inbound
      # size cap returned to the MTA. Status is the *domain's* (per-domain DNS).
      response = {
        found: true,
        org_id: org.id,
        org_key: org.key,
        status: domain_record.status,
        max_message_size_mb: org.effective_plan.max_message_size_mb
      }

      # E2EE sealing decision + material (docs/E2EE.md). Only report e2ee=true
      # when a sealing key actually exists — an enabled-but-keyless domain (key
      # provisioning not yet run) must fall back to plaintext, never half-seal.
      current_key = E2ee.effective?(domain_record) ? domain_record.current_e2ee_key : nil
      response[:e2ee] = current_key.present?
      if current_key
        response[:e2ee_public_key] = current_key.public_key
        response[:e2ee_key_version] = current_key.version
        response[:domain_id] = domain_record.id
        # Per-domain toggle: the MX includes a plaintext {from, subject}
        # notification preview alongside the sealed payload (docs/E2EE.md —
        # deliberate, documented leak for rich push alerts; default ON,
        # switchable off per domain for a fully content-free posture).
        response[:e2ee_notification_preview] = domain_record.e2ee_notification_preview
        # Sender filters ride along for sealed domains: Rails can't evaluate
        # them against a sealed row (no plaintext sender), so the MX applies
        # them in the ingestion window. Staleness ≤ the MX domain-cache TTL.
        filters = org.mail_filters.pluck(:kind, :value)
        response[:blocklist] = filters.filter_map { |k, v| v.downcase if k == MailFilter::KIND_BLOCKLIST }
        response[:allowlist] = filters.filter_map { |k, v| v.downcase if k == MailFilter::KIND_ALLOWLIST }
      end

      msg.respond(JSON.generate(response))
    end
  rescue => e
    Rails.logger.error("[NatsSubscriber] Domain lookup error: #{e.message}")
    msg.respond(JSON.generate({ found: false, error: "internal" }))
  end

  def setup_inbound_consumer
    # Create a durable pull consumer for processing inbound mail
    begin
      @js.consumer_info(STREAM_NAME, CONSUMER_NAME)
    rescue NATS::JetStream::Error::NotFound
      @js.add_consumer(STREAM_NAME, {
        durable_name: CONSUMER_NAME,
        filter_subject: INBOUND_SUBJECT,
        ack_policy: "explicit",
        ack_wait: 60, # 60s in nanoseconds
        max_deliver: 5,
        max_ack_pending: 100
      })
    end

    @psub = @js.pull_subscribe(INBOUND_SUBJECT, CONSUMER_NAME, stream: STREAM_NAME)
    Rails.logger.info("[NatsSubscriber] Inbound consumer active on #{STREAM_NAME}/#{CONSUMER_NAME}")

    Thread.new { consume_inbound_loop }
  end

  def consume_inbound_loop
    while @running
      begin
        msgs = @psub.fetch(10, timeout: 5)
        msgs.each do |msg|
          process_inbound_message(msg)
        end
      rescue NATS::IO::Timeout
        # No messages available, loop back
      rescue => e
        Rails.logger.error("[NatsSubscriber] Consume error: #{e.message}")
        sleep 1
      end
    end
  end

  def process_inbound_message(msg)
    payload = JSON.parse(msg.data)
    InboundMailProcessor.new(payload).process
    msg.ack
    Rails.logger.info("[NatsSubscriber] Processed inbound message: #{payload.dig('headers', 'message_id')}")
  rescue => e
    Rails.logger.error("[NatsSubscriber] Processing error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    msg.nak
  end

  def setup_delivery_status_consumer
    # Ensure the delivery status stream exists
    begin
      @js.find_stream_name_by_subject("mail.delivery.status.>")
    rescue NATS::JetStream::Error::NotFound
      @js.add_stream(
        name: STATUS_STREAM_NAME,
        subjects: [STATUS_SUBJECT],
        retention: "interest",
        max_age: 24 * 3600 * 1_000_000_000,
        max_bytes: 1024 * 1024 * 1024,
        storage: "file",
        discard: "old"
      )
    end

    begin
      @js.consumer_info(STATUS_STREAM_NAME, STATUS_CONSUMER_NAME)
    rescue NATS::JetStream::Error::NotFound
      @js.add_consumer(STATUS_STREAM_NAME, {
        durable_name: STATUS_CONSUMER_NAME,
        filter_subject: STATUS_SUBJECT,
        ack_policy: "explicit",
        ack_wait: 30,
        max_deliver: 3,
        max_ack_pending: 50
      })
    end

    @status_sub = @js.pull_subscribe(STATUS_SUBJECT, STATUS_CONSUMER_NAME, stream: STATUS_STREAM_NAME)
    Rails.logger.info("[NatsSubscriber] Delivery status consumer active on #{STATUS_STREAM_NAME}/#{STATUS_CONSUMER_NAME}")

    Thread.new { consume_delivery_status_loop }
  end

  def consume_delivery_status_loop
    while @running
      begin
        msgs = @status_sub.fetch(10, timeout: 5)
        msgs.each do |msg|
          process_delivery_status(msg)
        end
      rescue NATS::IO::Timeout
        # No messages available
      rescue => e
        Rails.logger.error("[NatsSubscriber] Delivery status consume error: #{e.message}")
        sleep 1
      end
    end
  end

  def process_delivery_status(msg)
    payload = JSON.parse(msg.data)
    delivery_status_key = payload["delivery_status_key"]
    # ESP deliveries ride the same queue under their own key (Esp::Publisher).
    if delivery_status_key.to_s.start_with?("#{Esp::Delivery.key_prefix}_")
      process_esp_delivery(delivery_status_key, payload)
      return msg.ack
    end

    delivery_status = DeliveryStatus.find_by(key: delivery_status_key)

    unless delivery_status
      Rails.logger.warn("[NatsSubscriber] DeliveryStatus not found: #{delivery_status_key}")
      msg.ack
      return
    end

    service = DeliveryRetryService.new(delivery_status)
    service.record_attempt(
      result: payload["result"],
      smtp_code: payload["smtp_code"],
      enhanced_code: payload["enhanced_code"],
      message: payload["response_message"]
    )

    # Schedule retry if needed (spec 20.2.3)
    if delivery_status.reload.status == DeliveryStatus::STATUS_DEFERRED && service.should_retry?
      delay = service.next_retry_delay
      OutboundRetryJob.set(wait: delay.seconds).perform_later(delivery_status.id)
      Rails.logger.info("[NatsSubscriber] Scheduled retry for #{delivery_status_key} in #{delay}s")
    end

    msg.ack
    Rails.logger.info("[NatsSubscriber] Processed delivery status: #{delivery_status_key} → #{payload['result']}")
  rescue => e
    Rails.logger.error("[NatsSubscriber] Delivery status processing error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    msg.nak
  end

  def process_esp_delivery(attempt_key, payload)
    key, attempt = attempt_key.split(":", 2)
    delivery = Esp::Delivery.find_by(key: key)
    return Rails.logger.warn("[NatsSubscriber] Esp::Delivery not found: #{key}") unless delivery

    retry_in = delivery.record_result!(attempt: attempt, result: payload["result"], smtp_code: payload["smtp_code"],
      enhanced_code: payload["enhanced_code"], response: payload["response_message"], mx_host: payload["mx_host"])
    Esp::DeliverJob.set(wait: retry_in.seconds).perform_later(delivery.id) if retry_in
  end

  def setup_signal_handlers
    %w[INT TERM].each do |signal|
      Signal.trap(signal) do
        @running = false
        Rails.logger.info("[NatsSubscriber] Shutting down...")
      end
    end
  end

  def wait
    while @running
      sleep 1
    end
    @nats&.drain
    @nats&.close
    Rails.logger.info("[NatsSubscriber] Stopped")
  end
end

NatsSubscriber.new.run if __FILE__ == $PROGRAM_NAME
