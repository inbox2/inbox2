namespace :threads do
  desc "Re-link conversations by re-normalizing subjects. Merges split threads."
  task relink: :environment do
    org = Organization.first
    abort "No organization found. Run `rails db:seed` first." unless org

    dataset_prefix = "[enron] "
    conversations = Conversation.where(organization: org)
      .where("subject LIKE ?", "#{dataset_prefix}%")
      .order(:created_at)

    total = conversations.count
    puts "\n=== Thread Re-linker ==="
    puts "  Organization: #{org.name} (#{org.default_domain&.name})"
    puts "  Conversations to evaluate: #{total}"
    puts ""

    # Phase 1: Build a map of normalized_subject -> [conversation_ids]
    puts "Phase 1: Building subject groups..."
    groups = Hash.new { |h, k| h[k] = [] }

    conversations.find_each.with_index do |conv, i|
      # Strip the dataset prefix, normalize, downcase for grouping
      raw_subject = conv.subject.delete_prefix(dataset_prefix)
      normalized = SubjectNormalizer.normalize(raw_subject).downcase.strip
      # Skip very short subjects to avoid false merges
      next if normalized.length < 5

      groups[normalized] << conv.id

      if (i + 1) % 25_000 == 0
        print "\r  Scanned #{i + 1}/#{total} conversations, #{groups.size} unique subjects"
      end
    end
    puts "\r  Scanned #{total}/#{total} conversations, #{groups.size} unique subjects"

    mergeable = groups.select { |_subj, ids| ids.size > 1 }
    puts "  Groups with multiple conversations (will merge): #{mergeable.size}"

    total_source_convs = mergeable.values.sum { |ids| ids.size - 1 }
    puts "  Conversations that will be merged away: #{total_source_convs}"
    puts ""

    if mergeable.empty?
      puts "Nothing to merge. All threads are correctly linked."
      next
    end

    # Phase 2: Merge conversations within each group
    puts "Phase 2: Merging split threads..."
    merged_conversations = 0
    moved_messages = 0
    errors = 0

    mergeable.each_with_index do |(normalized_subject, conv_ids), gi|
      # The target is the first (oldest) conversation in the group
      target_id = conv_ids.first
      source_ids = conv_ids[1..]

      ActiveRecord::Base.transaction do
        # Move all messages from source conversations to the target
        msg_count = Message.where(conversation_id: source_ids).update_all(conversation_id: target_id)
        moved_messages += msg_count

        # Move dependent records
        ConversationTag.where(conversation_id: source_ids).each do |ct|
          ct.update(conversation_id: target_id)
        rescue ActiveRecord::RecordNotUnique
          ct.destroy
        end

        ConversationAssignee.where(conversation_id: source_ids).each do |ca|
          ca.update(conversation_id: target_id)
        rescue ActiveRecord::RecordNotUnique
          ca.destroy
        end

        ConversationAccess.where(conversation_id: source_ids).each do |ca|
          ca.update(conversation_id: target_id)
        rescue ActiveRecord::RecordNotUnique
          ca.destroy
        end

        ActivityEvent.where(conversation_id: source_ids).update_all(conversation_id: target_id)
        Note.where(conversation_id: source_ids).update_all(conversation_id: target_id)

        # Delete the now-empty source conversations
        Conversation.where(id: source_ids).destroy_all
        merged_conversations += source_ids.size

        # Update the target conversation's subject to the normalized form
        target = Conversation.find(target_id)
        target.update!(
          subject: "#{dataset_prefix}#{SubjectNormalizer.normalize(target.subject.delete_prefix(dataset_prefix))}",
          snippet: target.messages.order(created_at: :desc).first&.body_plain&.truncate(200)
        )
      end

      if (gi + 1) % 5_000 == 0
        print "\r  Processed #{gi + 1}/#{mergeable.size} groups, merged #{merged_conversations} conversations, moved #{moved_messages} messages"
      end
    rescue => e
      errors += 1
      if errors <= 10
        puts "\n  Error merging group '#{normalized_subject.truncate(50)}': #{e.message}"
      elsif errors == 11
        puts "  (suppressing further error messages)"
      end
    end

    puts "\r  Processed #{mergeable.size}/#{mergeable.size} groups"
    puts ""

    # Phase 3: Stats
    puts "=== Results ==="
    puts "  Conversations merged away: #{merged_conversations}"
    puts "  Messages re-linked: #{moved_messages}"
    puts "  Errors: #{errors}"
    puts ""
    puts "  Before: #{total} conversations"
    puts "  After:  #{Conversation.where(organization: org).count} conversations"
    puts ""
  end

  desc "Dry-run: show what threads:relink would merge (no changes made)"
  task "relink:preview" => :environment do
    org = Organization.first
    abort "No organization found." unless org

    dataset_prefix = "[enron] "
    conversations = Conversation.where(organization: org)
      .where("subject LIKE ?", "#{dataset_prefix}%")
      .order(:created_at)

    groups = Hash.new { |h, k| h[k] = [] }

    conversations.find_each do |conv|
      raw_subject = conv.subject.delete_prefix(dataset_prefix)
      normalized = SubjectNormalizer.normalize(raw_subject).downcase.strip
      next if normalized.length < 5
      groups[normalized] << { id: conv.id, subject: conv.subject, message_count: conv.messages.size }
    end

    mergeable = groups.select { |_subj, entries| entries.size > 1 }
      .sort_by { |_subj, entries| -entries.size }

    puts "\n=== Thread Re-link Preview (dry run) ==="
    puts "  Total groups that would be merged: #{mergeable.size}"
    puts "  Conversations that would be merged away: #{mergeable.sum { |_subj, e| e.size - 1 }}"
    puts ""

    # Show top 30 largest groups
    mergeable.first(30).each_with_index do |(normalized, entries), i|
      puts "  #{i + 1}. \"#{normalized.truncate(60)}\" — #{entries.size} conversations, #{entries.sum { |e| e[:message_count] }} total messages"
      entries.first(5).each do |e|
        puts "     conv##{e[:id]}: \"#{e[:subject].truncate(70)}\" (#{e[:message_count]} msgs)"
      end
      puts "     ..." if entries.size > 5
    end
    puts ""
  end
end
