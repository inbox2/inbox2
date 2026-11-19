# A zone's category (docs/Calendar.md "Zones"): a name plus a palette colour.
# The colour is a key, never a hex — every client maps it to its own light/dark
# shade, so a zone reads right in every theme.
class ZoneCategory < ApplicationRecord
  key_prefix "zcat"

  COLORS = %w[blue amber violet green rose teal].freeze

  # Seeded the first time a user lists their categories.
  DEFAULTS = [
    { name: "Deep work", color: "blue" },
    { name: "Prep", color: "amber" },
    { name: "Admin", color: "violet" },
    { name: "Personal", color: "green" }
  ].freeze

  belongs_to :user
  has_many :zones, dependent: :nullify

  validates :name, presence: true, length: { maximum: 60 }
  validates :color, inclusion: { in: COLORS }

  def self.seed_defaults!(user)
    DEFAULTS.each_with_index { |d, i| user.zone_categories.create!(d.merge(position: i)) }
  end
end
