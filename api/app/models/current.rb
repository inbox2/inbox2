# Per-request context. membership: the viewer, so serializers show their own
# private labels (Tag.visible_to) without every call site passing it. Resolved
# on first use from the controller's resolver, so an endpoint that never
# serializes tags (or has no signed-in user) never looks it up. Nil in jobs and
# broadcasts, which then see org-wide tags only.
class Current < ActiveSupport::CurrentAttributes
  attribute :membership_resolver

  def membership
    return @membership if defined?(@membership)

    @membership = membership_resolver&.call
  end

  resets { remove_instance_variable(:@membership) if defined?(@membership) }
end
