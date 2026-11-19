# Builds the per-org deliverability screen state: the active mode + provider, the
# redacted saved config, and the full provider catalog driving the picker/form.
# Secret config fields (API keys, passwords) are never echoed back — only a
# boolean `<field>_set` so the form can show "configured" without leaking them.
class DeliverabilitySerializer
  def initialize(organization)
    @organization = organization
    @channel = DeliveryChannel.active_for(organization)
  end

  def to_h
    {
      mode: @channel.builtin? ? "builtin" : "custom",
      kind: @channel.kind,
      channel: @channel.custom? ? channel_summary : nil,
      config: @channel.custom? ? redacted_config(@channel) : {},
      providers: DeliveryProviders::CATALOG.map { |kind, meta| provider_descriptor(kind, meta) }
    }
  end

  private

  def channel_summary
    {
      key: @channel.key,
      name: @channel.name,
      kind: @channel.kind,
      status: @channel.status
    }
  end

  def redacted_config(channel)
    secrets = DeliveryProviders.secret_fields(channel.kind)
    cfg = (channel.config || {})
    out = {}
    DeliveryProviders.field_keys(channel.kind).each do |field|
      if secrets.include?(field)
        out["#{field}_set"] = cfg[field].present?
      else
        out[field] = cfg[field]
      end
    end
    out
  end

  def provider_descriptor(kind, meta)
    {
      kind: kind,
      label: meta[:label],
      icon: meta[:icon],
      blurb: meta[:blurb],
      fields: meta[:fields]
    }
  end
end
