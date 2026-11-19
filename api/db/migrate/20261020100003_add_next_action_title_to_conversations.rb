# Lore to-do title (docs/Triage.md "Next-action fields"): a short imperative
# written by the same OpenAI call as the one-line summary.
class AddNextActionTitleToConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :next_action_title, :string, limit: 80, if_not_exists: true
  end
end
