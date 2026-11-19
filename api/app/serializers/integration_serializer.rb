class IntegrationSerializer < ::ApplicationSerializer
  attributes :name, :provider, :status, :events, :created_at

  # Secret-bearing config values (e.g. Slack/Zapier incoming-webhook URLs) are
  # masked — see Integration#display_config.
  attribute :config do |integration|
    integration.display_config
  end

  attribute :token_expired do |integration|
    integration.token_expired?
  end

  # Never expose token digests
end
