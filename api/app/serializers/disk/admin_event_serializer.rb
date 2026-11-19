module Disk
  # An event in the console's org-wide activity (spec F11): the event plus
  # the item and share it concerns, so the list needs no second request.
  # A sealed item has no name here, as everywhere.
  class AdminEventSerializer < EventSerializer
    attribute :item do |e|
      next nil unless e.node

      { kind: e.node.kind, sealed: e.node.sealed?, name: e.node.sealed? ? nil : e.node.name }
    end

    attribute :share_name do |e|
      e.share&.name
    end
  end
end
