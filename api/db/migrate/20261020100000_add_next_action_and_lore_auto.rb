# Lore (docs/Triage.md "Next-action fields" + "Auto mode"): the due date and
# amount pulled from a thread's newest message, and each person's opt-in to let
# "Handled for you" buckets file mail away by themselves.
class AddNextActionAndLoreAuto < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :next_action_due_on, :date, if_not_exists: true
    add_column :conversations, :next_action_amount_cents, :bigint, if_not_exists: true
    add_column :conversations, :next_action_currency, :string, if_not_exists: true
    add_column :users, :lore_auto, :jsonb, default: {}, null: false, if_not_exists: true
  end
end
