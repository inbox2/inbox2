# Expands stored calendar rows into the concrete occurrences that fall inside a
# window. Without this a weekly standup renders exactly once — on the day the
# series started — because only the master row is stored.
#
# Three row shapes feed in (see CalendarEvent):
#   * single           — no recurrence_rule, used as-is
#   * recurring master — recurrence_rule set, expanded via ice_cube
#   * occurrence override — recurring_event_key + original_start_at, replaces the
#     generated instance it points at (status cancelled = that instance deleted)
#
# Returns unsaved CalendarEvent instances sorted by start, so callers serialize
# them exactly like persisted rows.
#
# IMPORTANT: pass a scope that has NOT been filtered with `not_cancelled`.
# A cancelled override is a tombstone — its whole job is to suppress the
# occurrence it points at — so filtering cancelled rows out before expansion
# makes deleted instances reappear. Cancellation is applied here instead.
class CalendarOccurrences
  def self.for_range(scope, range_start, range_end)
    new(scope, range_start, range_end).call
  end

  def initialize(scope, range_start, range_end)
    @scope = scope
    @range_start = range_start
    @range_end = range_end
  end

  def call
    (singles + expanded_masters + in_range_overrides)
      .select { |e| e.start_at < @range_end && e.end_at > @range_start }
      .sort_by(&:start_at)
  end

  private

  # Plain one-off events. Masters are excluded here (they come back through
  # expansion, which also emits the first occurrence) as are overrides.
  def singles
    @scope.not_cancelled
      .in_range(@range_start, @range_end)
      .where(recurrence_rule: [nil, ""], recurring_event_key: nil)
      .to_a
  end

  def masters
    # A master that starts after the window can contribute nothing; one that
    # started years ago still can, so there is no lower bound. A cancelled
    # master means the whole series is off.
    @masters ||= @scope.not_cancelled.recurring_masters.where("start_at < ?", @range_end).to_a
  end

  # Every override of the fetched masters, regardless of the window: an override
  # that moved its occurrence OUT of the window must still suppress the
  # generated instance sitting inside it.
  def overrides
    @overrides ||= begin
      keys = masters.map(&:key)
      keys.any? ? @scope.where(recurring_event_key: keys).to_a : []
    end
  end

  def overrides_by_master
    @overrides_by_master ||= overrides.group_by(&:recurring_event_key)
  end

  def expanded_masters
    masters.flat_map do |master|
      replaced = (overrides_by_master[master.key] || [])
        .filter_map { |o| o.original_start_at&.utc }
        .to_set

      master.occurrences_between(@range_start, @range_end)
        .reject { |start| replaced.include?(start.utc) }
        .map { |start| master.build_occurrence(start) }
    end
  end

  # Moved/edited instances render on their new date; cancelled ones only ever
  # existed to suppress a generated instance, so they never render themselves.
  def in_range_overrides
    overrides.reject(&:cancelled?)
  end
end
