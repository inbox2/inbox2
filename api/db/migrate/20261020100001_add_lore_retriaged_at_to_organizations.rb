# One-time re-triage after the five new built-in labels (docs/Triage.md
# "Upgrade re-triage"): set once LoreRetriageJob has queued an org's threads.
class AddLoreRetriagedAtToOrganizations < ActiveRecord::Migration[8.1]
  def change
    add_column :organizations, :lore_retriaged_at, :datetime, if_not_exists: true
  end
end
