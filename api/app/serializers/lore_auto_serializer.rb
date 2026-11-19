# `{ lore_auto: { fyi:, receipt:, notification: } }` — every key present, false unless turned on.
class LoreAutoSerializer
  include Alba::Resource

  root_key :lore_auto
  User::LORE_AUTO_LABELS.each do |label|
    attribute(label) { |user| user.lore_auto_on?(label) }
  end
end
