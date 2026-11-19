module Api
  module V1
    class CalendarEventsController < BaseController
      before_action :require_organization!

      # Attribute changes that invalidate an already-sent invitation and so
      # require a re-send with a bumped SEQUENCE (RFC 5546). Renaming the notes
      # on a meeting does not move anybody's day; moving it does.
      RESEND_TRIGGERS = %w[title start_at end_at location all_day status recurrence_rule].freeze

      # Ceiling on a single expanded response. A year-wide range over a daily
      # series is legitimate; a runaway one is not.
      MAX_RANGE_EVENTS = 2000

      # GET /api/v1/orgs/:org_id/events
      def index
        # Not `not_cancelled`: CalendarOccurrences needs to see cancelled
        # override rows, which are the tombstones that suppress deleted
        # occurrences. It applies cancellation itself.
        events = member_visible_events.includes(:attendees, :reminders, :calendar)

        if params[:calendar_ids].present?
          calendar_ids = current_organization.calendars.where(key: Array(params[:calendar_ids])).pluck(:id)
          events = events.where(calendar_id: calendar_ids)
        end

        if params[:q].present?
          q = "%#{params[:q]}%"
          events = events.where("title ILIKE ? OR description ILIKE ? OR location ILIKE ?", q, q, q)
        end

        range_start, range_end = parse_range
        if range_start && range_end
          # A calendar view always asks for a window, and only inside a window
          # can a repeating series be expanded into the instances the user
          # actually sees. Expansion happens in Ruby, so the row-level LIMIT is
          # applied to the result rather than the query.
          occurrences = CalendarOccurrences.for_range(events, range_start, range_end)
          total = occurrences.size
          occurrences = occurrences.first(MAX_RANGE_EVENTS)

          render json: {
            events: occurrences.map { |e| event_json(e) },
            meta: { total: total, truncated: total > occurrences.size }
          }
        else
          # No window: nothing to expand against, so this stays the plain
          # paginated row listing it always was.
          events, meta = paginate(events.not_cancelled.order(start_at: :asc), default_per_page: 100, max_per_page: 500)
          render json: { events: events.map { |e| event_json(e) }, meta: meta }
        end
      end

      # GET /api/v1/orgs/:org_id/events/:id
      def show
        event = find_event!
        render json: { event: event_json(event) }
      end

      # POST /api/v1/orgs/:org_id/events
      def create
        calendar = target_calendar
        event = calendar.calendar_events.build(event_params)
        event.organization = current_organization
        event.created_by_membership = current_active_membership!
        # The organizer is whoever created it — needed before the invitation is
        # built, and the address an inbound REPLY is matched against. Same
        # resolution as an RSVP, so both halves of a meeting agree on who we are.
        event.organizer_email = self_email
        event.organizer_name ||= current_user.display_name
        # Before the save, so the link is in the invitation the attendees get —
        # and so a failure costs nothing: there is no event yet to duplicate on
        # the retry.
        return unless attach_conference_link(event)

        ActiveRecord::Base.transaction do
          event.save!
          create_attendees(event) if params[:attendees].present?
          create_reminders(event) if params[:reminders].present?
        end

        event.reload
        # Attendees only mean something once they are told. Enqueued after the
        # transaction commits so a rollback cannot mail a phantom invitation —
        # and rescued, because the event is already saved: raising here would
        # report a created event as a failed request, and the retry would make
        # a second one.
        begin
          CalendarInviteDispatch.deliver(event, current_active_membership!)
        rescue StandardError => e
          Rails.logger.error("[calendar] invitation for #{event.key} not sent: #{e.class}: #{e.message}")
        end
        broadcast_calendar_event("event_created", event)

        render json: { event: event_json(event) }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: ErrorSerializer.serialize(e.record.errors.full_messages, status: 422), status: :unprocessable_content
      end

      # PATCH /api/v1/orgs/:org_id/events/:id
      # `scope=all` on an instance of a series moves the whole series by the
      # same amount (the drag-to-reschedule "All events"); otherwise one instance
      # is split off. `notify=false` saves without mailing the guests.
      def update
        event, occurrence_start = locate_event!(member_editable_events)
        master = %w[all following].include?(params[:scope]) ? series_master(event) : nil
        # The instance being edited, in the series' own terms: a generated
        # occurrence's slot, or the slot an exception row replaced.
        instance_start = occurrence_start || event.original_start_at || event.start_at
        @truncated = nil

        ActiveRecord::Base.transaction do
          if master && params[:scope] == "following" && instance_start > master.start_at
            event = split_series!(master, instance_start)
            @truncated = master
          elsif master
            shift_series!(master, instance_start)
            event = master
          else
            # Editing one instance of a series splits it off as an exception row
            # rather than rewriting every future occurrence. An instance can't
            # carry a rule of its own — that's an edit to all or following.
            event = split_occurrence!(event, occurrence_start) if occurrence_start
            attrs = event.recurring_event_key.present? ? event_update_params.except(:recurrence_rule) : event_update_params
            event.assign_attributes(attrs)
          end
          # A split-off tail is a new meeting: its guests need the invitation.
          resend = event.changed.intersect?(RESEND_TRIGGERS) || @truncated.present?
          # RFC 5546: a changed invitation must carry a higher SEQUENCE or
          # recipients' clients discard it as a stale duplicate.
          event.sequence = event.sequence.to_i + 1 if resend && event.attendees.any?
          @resend = resend
          event.save!
          sync_attendees(event) if params[:attendees].present?
          sync_reminders(event) if params[:reminders].present?
        end

        event.reload
        # Only the organizer re-invites: editing an invite you accepted is a change
        # to your own copy, not a new invitation to everyone on it.
        notify = params[:notify].to_s != "false"
        if notify && (@resend || params[:attendees].present?) && event.organized_by?(my_addresses)
          CalendarInviteDispatch.deliver(backfill_organizer!(event), current_active_membership!)
        end
        # The series that now ends before the split: its guests get the shorter
        # rule, or their calendars keep both halves.
        if notify && @truncated&.attendees&.any? && @truncated.organized_by?(my_addresses)
          @truncated.update_column(:sequence, @truncated.sequence.to_i + 1)
          CalendarInviteDispatch.deliver(backfill_organizer!(@truncated.reload), current_active_membership!)
        end
        broadcast_calendar_event("event_updated", event)

        render json: { event: event_json(event) }
      rescue ActiveRecord::RecordInvalid => e
        render json: ErrorSerializer.serialize(e.record.errors.full_messages, status: 422), status: :unprocessable_content
      end

      # DELETE /api/v1/orgs/:org_id/events/:id
      def destroy
        event, occurrence_start = locate_event!(member_editable_events)
        scope = params[:scope].presence || "this"
        # Tell attendees before the rows are gone — the cancellation notice is
        # built from the event it is cancelling.
        notify_cancellation(event, occurrence_start, scope)

        case scope
        when "following" then destroy_following(event, occurrence_start)
        when "all" then destroy_series(event)
        else destroy_single(event, occurrence_start)
        end

        broadcast_calendar_event("event_deleted", event)
        head :no_content
      end

      # POST /api/v1/orgs/:org_id/events/:id/rsvp
      def rsvp
        event, occurrence_start = locate_event!
        status = params.require(:status)

        unless CalendarAttendee::RESPONSE_STATUSES.include?(status)
          return render json: ErrorSerializer.serialize("Invalid RSVP status", status: 422), status: :unprocessable_content
        end

        # Answering one instance of a series must not answer the whole series.
        event = split_occurrence!(event, occurrence_start) if occurrence_start

        attendee = find_or_build_self_attendee(event)
        attendee.response_status = status
        attendee.responded_at = Time.current
        attendee.comment = params[:comment] if params[:comment].present?
        attendee.save!

        # An RSVP is only half an answer until the organizer hears it. Skipped
        # when we are the organizer — nobody needs mail about their own event.
        CalendarRsvpNotifier.notify(event, attendee, current_active_membership!)
        broadcast_calendar_event("rsvp_updated", event)

        render json: { event: event_json(event.reload) }
      end

      # POST /api/v1/orgs/:org_id/events/:id/propose-time
      def propose_time
        event, occurrence_start = locate_event!
        event = split_occurrence!(event, occurrence_start) if occurrence_start

        proposed_start = parse_time(params[:proposed_start])
        if proposed_start.nil?
          return render json: ErrorSerializer.serialize("proposed_start is required", status: 422),
                        status: :unprocessable_content
        end

        attendee = find_or_build_self_attendee(event)
        attendee.response_status = CalendarAttendee::RESPONSE_TENTATIVE
        attendee.responded_at = Time.current
        attendee.proposed_start = proposed_start
        attendee.proposed_end = parse_time(params[:proposed_end]) || (proposed_start + event.duration)
        attendee.comment = params[:comment]
        attendee.save!

        # A proposal nobody sees is a dropped message — mail the organizer a
        # METHOD:COUNTER so their client offers it too.
        CalendarProposal.notify(event, attendee, current_active_membership!)
        broadcast_calendar_event("proposal_received", event)
        render json: { event: event_json(event.reload) }
      end

      # POST /api/v1/orgs/:org_id/events/:id/accept-proposal
      # Organizer takes an attendee up on their suggested time: the event moves
      # and a fresh invitation goes out. Organizer-only — it reschedules.
      def accept_proposal
        event, occurrence_start = locate_event!(member_editable_events)
        event = split_occurrence!(event, occurrence_start) if occurrence_start
        attendee = find_proposing_attendee!(event)

        moved = CalendarProposal.accept!(backfill_organizer!(event), attendee, current_active_membership!)
        if moved.nil?
          return render json: ErrorSerializer.serialize("no pending proposal", status: 422),
                        status: :unprocessable_content
        end

        broadcast_calendar_event("event_updated", moved)
        render json: { event: event_json(moved.reload) }
      end

      # POST /api/v1/orgs/:org_id/events/:id/decline-proposal
      def decline_proposal
        event, occurrence_start = locate_event!(member_editable_events)
        event = split_occurrence!(event, occurrence_start) if occurrence_start
        attendee = find_proposing_attendee!(event)

        CalendarProposal.decline!(backfill_organizer!(event), attendee, current_active_membership!)
        broadcast_calendar_event("event_updated", event)
        render json: { event: event_json(event.reload) }
      end

      # GET /api/v1/orgs/:org_id/events/free-busy
      def free_busy
        emails = Array(params[:emails]).map { |e| e.to_s.downcase }
        range_start, range_end = parse_range
        if range_start.nil? || range_end.nil?
          return render json: ErrorSerializer.serialize("invalid start/end", status: 422), status: :unprocessable_content
        end
        return render json: { free_busy: {} } if emails.empty?

        # Org-wide, busy-only. Scheduling against a colleague is the whole point
        # of free/busy, and it is safe precisely because a block is a start and
        # an end — no title, location, guest list or event id (see FreeBusy).
        render json: { free_busy: FreeBusy.new(org_events, schedulable(emails), range_start, range_end, organization: current_organization).call }
      end

      # GET /api/v1/orgs/:org_id/events/availability
      #
      # The scheduling assistant behind the "Find a time" popup: every
      # attendee's identity, timezone, working day and busy blocks, plus ranked
      # slots that suit everybody — in one round trip, because drawing one grid
      # should not cost five requests.
      def availability
        emails = Array(params[:emails]).map { |e| e.to_s.downcase }
        range_start, range_end = parse_range
        if range_start.nil? || range_end.nil?
          return render json: ErrorSerializer.serialize("invalid start/end", status: 422), status: :unprocessable_content
        end

        # The organizer's own day belongs on the grid without having to invite
        # themselves — Outlook and Google both put you on the first row.
        emails = schedulable(([self_email.to_s.downcase] + emails).uniq.reject(&:blank?))

        result = Availability.new(
          organization: current_organization,
          membership: current_active_membership!,
          emails: emails,
          range_start: range_start,
          range_end: range_end,
          duration_minutes: params[:duration_minutes]
        ).call

        render json: result
      end

      # GET /api/v1/orgs/:org_id/events/directory
      # The org's own addresses, so "invite people" can suggest colleagues
      # instead of relying on whoever happens to be in the contact history.
      def directory
        people = OrgDirectory.new(current_organization, membership: current_active_membership!).people
        render json: {
          people: people.map { |p| { email: p.email, name: p.name, timezone: p.timezone, internal: true } }
        }
      end

      # POST /api/v1/orgs/:org_id/events/from-ics
      def create_from_ics
        ics_content = params.require(:ics_content)
        calendar = target_calendar

        begin
          event_data_list = IcsParser.new(ics_content).parse
        rescue IcsParser::ParseError => e
          return render json: ErrorSerializer.serialize("Failed to parse ICS: #{e.message}", status: 422),
                        status: :unprocessable_content
        end

        created = ActiveRecord::Base.transaction do
          event_data_list.map do |event_data|
            event = calendar.calendar_events.find_or_initialize_by(ical_uid: event_data[:uid])
            event.assign_attributes(
              organization: current_organization,
              title: event_data[:summary] || "(No title)",
              description: event_data[:description],
              location: event_data[:location],
              start_at: event_data[:dtstart],
              end_at: event_data[:dtend],
              all_day: event_data[:all_day] || false,
              timezone: event_data[:timezone] || "UTC",
              organizer_email: event_data[:organizer_email],
              organizer_name: event_data[:organizer_name],
              recurrence_rule: event_data[:rrule],
              sequence: event_data[:sequence] || 0,
              created_by_membership: current_active_membership!
            )
            event.save!
            import_attendees(event, event_data)
            event
          end
        end

        broadcast_calendar_event("event_created", created.first) if created.any?
        render json: { events: created.map { |e| event_json(e.reload) } }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: ErrorSerializer.serialize(e.record.errors.full_messages, status: 422), status: :unprocessable_content
      end

      private

      def event_json(event)
        CalendarEventSerializer.new(event, params: { my_addresses: my_addresses }).to_h
      end

      # Every address this member answers as — what decides organized_by?.
      def my_addresses
        @my_addresses ||= (current_active_membership!.email_addresses + [self_email]).compact.uniq
      end

      # A domain-scoped member schedules against their own teams and outside
      # guests only, never a colleague on one of the org's other domains (E3).
      def schedulable(emails)
        me = current_active_membership!
        return emails if me.all_domains_access?

        foreign = current_organization.domains.where.not(id: me.home_domain_ids).pluck(:name).map(&:downcase)
        emails.reject { |e| foreign.include?(e.to_s.split("@", 2).last.to_s.downcase) }
      end

      def parse_range
        return [nil, nil] if params[:start].blank? || params[:end].blank?

        [Time.zone.parse(params[:start].to_s), Time.zone.parse(params[:end].to_s)]
      rescue ArgumentError
        [nil, nil]
      end

      # The named calendar, or the member's own default. Falling back means a
      # brand-new member can create an event before ever creating a calendar.
      def target_calendar
        if params[:calendar_id].present?
          current_organization.calendars.for_member(current_active_membership!).find_by!(key: params[:calendar_id])
        else
          Calendar.primary_for(current_organization, current_active_membership!)
        end
      end

      def find_event!
        event, occurrence_start = locate_event!
        occurrence_start ? event.build_occurrence(occurrence_start) : event
      end

      # Resolves a public id to [persisted_row, occurrence_start_or_nil]. The id
      # may name a whole event ("cev_abc") or one instance of a series
      # ("cev_abc@20260101T090000Z") — the form the expanded index handed out.
      # `scope` decides whether being invited is enough (read) or ownership is
      # required (write).
      def locate_event!(scope = member_visible_events)
        series_key, occurrence_start = CalendarEvent.parse_occurrence_id(params[:id])
        event = scope.includes(:attendees, :reminders, :calendar).find_by!(key: series_key)
        # An id with no occurrence stamp addresses the row itself; a stamp on a
        # non-recurring row is meaningless and ignored.
        [event, event.recurring_master? ? occurrence_start : nil]
      end

      # Materializes one generated instance of a series as a real exception row
      # so it can carry its own edits, attendees and RSVPs.
      def split_occurrence!(master, occurrence_start)
        existing = master.calendar.calendar_events
          .find_by(recurring_event_key: master.key, original_start_at: occurrence_start)
        return existing if existing

        override = master.dup
        override.assign_attributes(
          key: nil,
          # RFC 5545: an exception shares the series' UID and is told apart by
          # its RECURRENCE-ID. A fresh UID would read as a separate meeting in
          # the recipient's client, leaving the original occurrence in place.
          ical_uid: master.ical_uid,
          recurrence_rule: nil,
          recurring_event_key: master.key,
          original_start_at: occurrence_start,
          start_at: occurrence_start,
          end_at: occurrence_start + master.duration
        )
        override.save!
        # The instance inherits the series' guest list; without it, RSVPing to
        # one occurrence would silently drop everyone else from that day.
        master.attendees.each do |att|
          override.attendees.create!(
            email: att.email, name: att.name,
            is_organizer: att.is_organizer, is_optional: att.is_optional
          )
        end
        override.reload
      end

      # The master row of the series `event` is part of, or nil for a one-off.
      def series_master(event)
        return event if event.recurring_master?
        return nil if event.recurring_event_key.blank?

        event.calendar.calendar_events.find_by(key: event.recurring_event_key)
      end

      # Moves the series by however far the instance that started at
      # `instance_start` was moved, giving it the instance's new length; other
      # edits in the params apply to the series too. Exceptions move along — an
      # exception still pinned to the old slot would draw next to the moved one.
      # ponytail: a shift onto another weekday leaves BYDAY rules behind; the
      # client offers "All events" only for same-day moves.
      def shift_series!(master, instance_start)
        new_start = parse_time(params[:start_at]) || instance_start
        new_end = parse_time(params[:end_at]) || (new_start + master.duration)
        shift = new_start - instance_start

        master.assign_attributes(event_update_params.except(:start_at, :end_at))
        exceptions = master.calendar.calendar_events.where(recurring_event_key: master.key)
        if master.recurrence_rule.blank?
          # "All events → does not repeat" keeps the one you were looking at,
          # at its new time — not the series' first date, long gone by now.
          master.start_at = new_start
          master.end_at = new_end
          return exceptions.destroy_all
        end

        master.start_at += shift
        master.end_at = master.start_at + (new_end - new_start)
        exceptions.find_each do |exc|
          # A new rule makes new slots. An exception keeps its edits and RSVPs
          # if its (moved) slot is still one of them, and is dropped only when
          # the rule no longer reaches it.
          if master.recurrence_rule_changed? && !master.occurs_at?(exc.original_start_at + shift)
            exc.destroy!
            next
          end
          unmoved = exc.start_at == exc.original_start_at
          exc.original_start_at += shift
          if unmoved
            exc.start_at += shift
            exc.end_at = exc.start_at + (new_end - new_start)
          end
          exc.save!
        end
      end

      # "This and following": the series stops just before `cutoff` and the rest
      # becomes a series of its own, taking the edits. A fresh UID — RFC 5545
      # can't re-rule part of a series, so Google and Outlook split it this way.
      def split_series!(master, cutoff)
        rule = params.key?(:recurrence_rule) ? params[:recurrence_rule].presence : master.recurrence_rule
        rule_kept = rule == master.recurrence_rule
        # An unchanged COUNT counts what's left, not the whole series again.
        if rule_kept && (count = rule.to_s[/COUNT=(\d+)/i, 1])
          done = master.occurrences_between(master.start_at, cutoff - 1.second).count { |t| t < cutoff }
          rule = rule.sub(/COUNT=\d+/i, "COUNT=#{[count.to_i - done, 1].max}")
        end

        new_start = parse_time(params[:start_at]) || cutoff
        new_end = parse_time(params[:end_at]) || (new_start + master.duration)
        tail = master.dup
        tail.assign_attributes(event_update_params.except(:start_at, :end_at, :recurrence_rule))
        tail.assign_attributes(key: nil, ical_uid: nil, sequence: 0, recurrence_rule: rule,
                               start_at: new_start, end_at: new_end)
        tail.save!
        master.attendees.each do |att|
          tail.attendees.create!(email: att.email, name: att.name,
                                 is_organizer: att.is_organizer, is_optional: att.is_optional)
        end
        # Reminders too, unless the request sends its own (update re-syncs them).
        master.reminders.each { |r| tail.reminders.create!(method: r.method, minutes_before: r.minutes_before) }

        later = master.calendar.calendar_events.where(recurring_event_key: master.key).where(original_start_at: cutoff..)
        if rule_kept && new_start == cutoff
          later.update_all(recurring_event_key: tail.key, ical_uid: tail.reload.ical_uid)
        else
          later.destroy_all
        end
        master.truncate_series_before!(cutoff)
        tail.reload
      end

      def destroy_single(event, occurrence_start)
        # Deleting one instance of a series leaves a cancelled exception row
        # behind — that tombstone is what suppresses the generated occurrence.
        if occurrence_start
          override = split_occurrence!(event, occurrence_start)
          override.update!(status: CalendarEvent::STATUS_CANCELLED)
        else
          event.destroy!
        end
      end

      def destroy_following(event, occurrence_start)
        cutoff = occurrence_start || event.start_at
        unless event.recurring_master?
          event.destroy!
          return
        end

        # Pinning UNTIL ends the series; exceptions after the cutoff would
        # otherwise survive as orphans pointing at a series that no longer
        # reaches them.
        event.calendar.calendar_events
          .where(recurring_event_key: event.key)
          .where(original_start_at: cutoff..)
          .destroy_all

        if cutoff <= event.start_at
          event.destroy!
        else
          event.truncate_series_before!(cutoff)
        end
      end

      def destroy_series(event)
        master_key = event.recurring_event_key.presence || event.key
        event.calendar.calendar_events.where(recurring_event_key: master_key).destroy_all
        event.calendar.calendar_events.find_by(key: master_key)&.destroy!
      end

      # Cancelling one instance mails a CANCEL for that instance (it is split
      # into a real row first, so it carries its own RECURRENCE-ID); cancelling
      # the series mails one CANCEL for the whole thing.
      def notify_cancellation(event, occurrence_start, scope)
        target = occurrence_start && scope == "this" ? split_occurrence!(event, occurrence_start) : event
        return if target.attendees.empty?
        # Deleting an invite you accepted removes your copy; the meeting still
        # happens. The organizer hears about it only if you decline (rsvp).
        return unless target.organized_by?(my_addresses)

        # SEQUENCE must advance on a cancellation too, or clients that already
        # saw the invitation treat the CANCEL as a stale duplicate and ignore it.
        target.update_column(:sequence, target.sequence.to_i + 1)
        backfill_organizer!(target)
        CalendarInviteDispatch.deliver(target.reload, current_active_membership!,
                                       action: CalendarInviteDispatch::ACTION_CANCEL)
      end

      # READ scope: own/shared calendars plus anything we were invited to, so an
      # internal invitation shows up on the guest's calendar with no row copied.
      def member_visible_events
        org_events.visible_to(current_active_membership!)
      end

      # WRITE scope: calendars only. Being invited to a meeting must not let you
      # retitle, reschedule or delete it — only the owner side can.
      def member_editable_events
        org_events.editable_by(current_active_membership!)
      end

      # Always anchored to the authenticated org (E3).
      def org_events
        CalendarEvent.where(organization_id: current_organization.id)
      end

      # The address this member answers as. A real Mailbox on one of the org's
      # domains is what an organizer's client will see in the REPLY, so it wins;
      # username@domain is the address every member may send as even without a
      # mailbox (Membership#can_send_as?). The external billing address is a
      # last resort for an org with no domain yet — nothing can be sent from it.
      def self_email
        @self_email ||= current_active_membership!.primary_email_address.presence ||
          (current_organization.default_domain && "#{current_user.username}@#{current_organization.default_domain.name}") ||
          current_user.billing_email.presence
      end

      # Every event created before invitations existed has a blank organizer,
      # and without one there is no address to send an update or cancellation
      # from. Backfilled on first touch — from the creator where we still know
      # them, otherwise from whoever is acting now.
      def backfill_organizer!(event)
        return event if event.organizer_email.present?

        email = event.created_by_membership&.primary_email_address.presence || self_email
        event.update_column(:organizer_email, email)
        event
      end

      # The attendee whose proposal is being answered — named explicitly, since an
      # event can carry more than one suggestion at a time.
      def find_proposing_attendee!(event)
        email = params[:attendee_email].to_s.downcase
        scope = event.attendees.where.not(proposed_start: nil)
        attendee = email.present? ? scope.where("LOWER(email) = ?", email).first : scope.first
        raise ActiveRecord::RecordNotFound, "no proposal from #{email.presence || 'any attendee'}" if attendee.nil?

        attendee
      end

      def parse_time(value)
        value.present? ? Time.zone.parse(value.to_s) : nil
      rescue ArgumentError
        nil
      end

      def find_or_build_self_attendee(event)
        event.attendees.where("LOWER(email) = ?", self_email.downcase).first ||
          event.attendees.build(email: self_email, name: current_user.display_name)
      end

      # `conference` asks the member's connected Google/Microsoft account for a
      # Meet/Teams link (docs/Calendar.md) and parks it in `location`, where
      # every client already looks for the meeting URL.
      #
      # A requested link that can't be made fails the create (422), rather than
      # quietly saving an event with no video call in it: the caller asked for
      # one, nothing has been written yet, and the editor is still open to say
      # so. (The meet-link accept path deliberately does the opposite — there a
      # visitor's booking must survive a flaky Meet API.) Returns false when it
      # has rendered an error and the caller must stop.
      def attach_conference_link(event)
        mode = params[:conference].to_s
        return true if mode.blank?

        provider = ConferenceLink::PROVIDER_FOR_MODE[mode]
        return conference_error("Unsupported video call: #{mode}") if provider.nil?

        connection = ConferencingConnection.find_by(membership: current_active_membership!, provider: provider)
        if connection.nil?
          return conference_error(
            "Connect your #{provider.capitalize} account in Settings › Scheduling to add a video call."
          )
        end

        url = ConferenceLink.generate(
          connection, subject: event.title, start_at: event.start_at, end_at: event.end_at
        )
        return conference_error("The video call couldn't be created. Try again, or save without one.") if url.blank?

        event.location = event.location.present? ? "#{event.location} · #{url}" : url
        true
      end

      def conference_error(message)
        render json: ErrorSerializer.serialize(message, status: 422), status: :unprocessable_content
        false
      end

      # `organizer_email` is deliberately NOT accepted from the client: the
      # organizer is whoever creates the event (resolved server-side in #create),
      # and the invitation goes out From that address through the org's own
      # DKIM-signing MTA — accepting it here let any member mail invites as
      # anyone. Imported invites set their external organizer directly.
      def event_params
        params.permit(:title, :description, :location, :start_at, :end_at, :all_day,
                       :timezone, :status, :visibility, :recurrence_rule, :ical_uid,
                       :organizer_name, :conversation_key)
      end

      def event_update_params
        params.permit(:title, :description, :location, :start_at, :end_at, :all_day,
                       :timezone, :status, :visibility, :recurrence_rule,
                       :organizer_name)
      end

      def create_attendees(event)
        Array(params[:attendees]).each do |att|
          next if att[:email].blank?

          event.attendees.create!(
            email: att[:email],
            name: att[:name],
            is_organizer: att[:is_organizer] || false,
            is_optional: att[:is_optional] || false
          )
        end
      end

      def sync_attendees(event)
        incoming_emails = Array(params[:attendees]).filter_map { |a| a[:email].presence }

        event.attendees.where.not(email: incoming_emails).destroy_all

        Array(params[:attendees]).each do |att|
          next if att[:email].blank?

          attendee = event.attendees.find_or_initialize_by(email: att[:email])
          attendee.name = att[:name] if att[:name].present?
          attendee.is_organizer = att[:is_organizer] if att.key?(:is_organizer)
          attendee.is_optional = att[:is_optional] if att.key?(:is_optional)
          attendee.save!
        end
      end

      def import_attendees(event, event_data)
        Array(event_data[:attendees]).each do |att|
          next if att[:email].blank?

          row = event.attendees.where("LOWER(email) = ?", att[:email].downcase).first ||
            event.attendees.build(email: att[:email])
          row.name = att[:name] if att[:name].present?
          row.is_optional = !!att[:optional]
          row.is_organizer = att[:email].casecmp?(event_data[:organizer_email].to_s)
          row.response_status = InboundCalendarResponse::PARTSTAT_TO_STATUS
            .fetch(att[:partstat].to_s.upcase, CalendarAttendee::RESPONSE_NEEDS_ACTION)
          row.save!
        end
      end

      def create_reminders(event)
        Array(params[:reminders]).each do |rem|
          event.reminders.create!(
            method: rem[:method] || "popup",
            minutes_before: rem[:minutes_before]
          )
        end
      end

      def sync_reminders(event)
        event.reminders.destroy_all
        create_reminders(event)
      end

      def broadcast_calendar_event(type, event)
        ActionCable.server.broadcast(
          "calendar_#{current_organization.key}",
          { type: type, event_id: event.key }
        )
      rescue => e
        Rails.logger.warn("[CalendarEventsController] Broadcast error: #{e.message}")
      end
    end
  end
end
