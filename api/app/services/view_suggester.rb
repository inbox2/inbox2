# Analyzes conversation patterns and suggests filter-based views (spec 3.3.8)
class ViewSuggester
  MAX_SUGGESTIONS = 5

  # conversations: the caller's visible slice, so a domain-scoped member gets no
  # counts from mail they can't read.
  def initialize(organization, conversations: organization.conversations)
    @organization = organization
    @conversations = conversations
  end

  def suggest
    suggestions = []
    suggestions.concat(top_sender_domains)
    suggestions.concat(top_tags)
    suggestions.concat(high_volume_recipients)
    suggestions.first(MAX_SUGGESTIONS)
  end

  private

  def top_sender_domains
    # Grouped in SQL: the old pluck pulled every sender address into Ruby to tally.
    domains = @conversations
      .where.not(from_address: [nil, ""])
      .group(Arel.sql("split_part(from_address, '@', 2)"))
      .order(Arel.sql("count_all DESC"))
      .limit(3)
      .count
      .reject { |domain, _| domain.blank? }

    existing_filters = existing_view_filters

    domains.filter_map do |domain, count|
      next if count < 3

      filter = [{ "field" => "sender", "operator" => "ends_with", "value" => "@#{domain}" }]
      next if existing_filters.include?(filter)

      {
        name: "From #{domain}",
        icon: "envelope",
        filters: filter,
        reason: "#{count} conversations from this domain"
      }
    end
  end

  def top_tags
    tag_counts = @organization.tags.org_wide
      .joins("INNER JOIN conversation_tags ON conversation_tags.tag_id = tags.id")
      .where(conversation_tags: { conversation_id: @conversations.select(:id) })
      .group("tags.id", "tags.name")
      .order("count_all DESC")
      .limit(3)
      .count

    existing_filters = existing_view_filters

    tag_counts.filter_map do |(_, tag_name), count|
      next if count < 2

      filter = [{ "field" => "tag", "operator" => "equals", "value" => tag_name }]
      next if existing_filters.include?(filter)

      {
        name: "Tagged: #{tag_name}",
        icon: "tag",
        filters: filter,
        reason: "#{count} conversations with this tag"
      }
    end
  end

  def high_volume_recipients
    recipients = @conversations
      .where.not(to_address: [nil, ""])
      .group(:to_address)
      .order(Arel.sql("count_all DESC"))
      .limit(2)
      .count

    existing_filters = existing_view_filters

    recipients.filter_map do |address, count|
      next if count < 3

      filter = [{ "field" => "recipient", "operator" => "equals", "value" => address }]
      next if existing_filters.include?(filter)

      {
        name: "To #{address}",
        icon: "tray",
        filters: filter,
        reason: "#{count} conversations to this address"
      }
    end
  end

  def existing_view_filters
    @existing_view_filters ||= @organization.views.pluck(:filters).to_set
  end
end
