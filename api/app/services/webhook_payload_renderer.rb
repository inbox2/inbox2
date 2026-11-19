# Renders custom webhook payload templates with conversation/message data (spec 7.4.6-7.4.7)
# Template values use {{dotted.path}} placeholders replaced with actual data.
class WebhookPayloadRenderer
  def initialize(webhook, conversation, message: nil, event: nil)
    @webhook = webhook
    @conversation = conversation
    @message = message
    @event = event
  end

  def render
    template = @webhook.payload_template
    return default_payload if template.blank?

    render_template(template)
  end

  private

  def render_template(obj)
    case obj
    when Hash
      obj.transform_values { |v| render_template(v) }
    when Array
      obj.map { |v| render_template(v) }
    when String
      interpolate(obj)
    else
      obj
    end
  end

  def interpolate(str)
    str.gsub(/\{\{(\w+(?:\.\w+)*)\}\}/) do |_match|
      path = $1
      resolve(path).to_s
    end
  end

  def resolve(path)
    parts = path.split(".")
    root = parts.shift

    value = case root
    when "conversation" then conversation_data.dig(*parts)
    when "message" then message_data.dig(*parts)
    when "event" then @event
    when "organization" then organization_data.dig(*parts)
    else nil
    end

    value || ""
  end

  def conversation_data
    @conversation_data ||= {
      "id" => @conversation.key,
      "subject" => @conversation.subject,
      "status" => @conversation.status,
      "from_address" => @conversation.from_address,
      "to_address" => @conversation.to_address
    }
  end

  def message_data
    return {} unless @message

    @message_data ||= {
      "id" => @message.key,
      "from_address" => @message.from_address,
      "to_address" => @message.to_address,
      "subject" => @message.subject,
      "body" => @message.body_plain
    }
  end

  def organization_data
    org = @conversation.organization
    @organization_data ||= {
      "id" => org.key,
      "domain" => org.default_domain&.name
    }
  end

  def default_payload
    {
      "event" => @event,
      "conversation" => conversation_data,
      "message" => @message ? message_data : nil
    }.compact
  end
end
