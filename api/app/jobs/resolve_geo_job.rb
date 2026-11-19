# Resolves a tracking record's IP → city/country out of the request path (the
# pixel/redirect endpoints must stay fast — mail clients hammer them). Generic
# over any model with ip/geo_country/geo_city columns (MessageOpen, LinkClick).
# ponytail: free ip-api.com, cached per IP. Swap for a local MaxMind DB if the
# 45 req/min free ceiling ever bites.
require "net/http"

class ResolveGeoJob < ApplicationJob
  queue_as :default

  RESOLVABLE = %w[MessageOpen LinkClick].freeze

  def perform(model, id)
    return unless RESOLVABLE.include?(model)

    record = model.constantize.find_by(id: id)
    return if record.nil? || record.ip.blank? || record.geo_country.present?
    return if private_ip?(record.ip)

    geo = Rails.cache.fetch("open_geo:#{record.ip}", expires_in: 30.days) { lookup(record.ip) }
    return if geo.blank?

    record.update!(geo_country: geo[:country], geo_city: geo[:city])
  end

  private

  def lookup(ip)
    uri = URI("http://ip-api.com/json/#{ip}?fields=status,country,city")
    res = Net::HTTP.get_response(uri)
    return nil unless res.is_a?(Net::HTTPSuccess)

    data = JSON.parse(res.body)
    return nil unless data["status"] == "success"

    { country: data["country"], city: data["city"] }
  rescue => e
    Rails.logger.warn("[ResolveGeoJob] geo lookup failed for #{ip}: #{e.message}")
    nil
  end

  def private_ip?(ip)
    addr = IPAddr.new(ip)
    addr.private? || addr.loopback? || addr.link_local?
  rescue IPAddr::Error
    true
  end
end
