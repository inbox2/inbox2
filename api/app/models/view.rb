class View < ApplicationRecord
  key_prefix "view"

  KINDS = %w[system personal].freeze
  KIND_SYSTEM = "system".freeze
  KIND_PERSONAL = "personal".freeze

  # Inbox is the open unified pool (every member sees the whole domain's open
  # mail), matching ConversationsController#unread_count. It is NOT "assigned to
  # me" — that was the old name (see SYSTEM_VIEW_RENAMES); the filter is migrated
  # to status=open by ensure_system_views.
  SYSTEM_VIEWS = [
    { name: "Inbox", icon: "tray", filters: [{ "field" => "status", "operator" => "equals", "value" => Conversation::STATUS_OPEN }] },
    { name: "Sent", icon: "paperplane", filters: [{ "field" => "direction", "operator" => "equals", "value" => "outbound" }] },
    { name: "Drafts", icon: "doc", filters: [{ "field" => "is_draft", "operator" => "equals", "value" => "true" }] },
    { name: "All Mail", icon: "tray.full", filters: [] },
    { name: "Mentioned", icon: "at", filters: [{ "field" => "mentioned", "operator" => "is_me" }] },
    { name: "Unassigned", icon: "person.slash", filters: [{ "field" => "assignee", "operator" => "is_empty" }] }
  ].freeze

  belongs_to :organization
  belongs_to :membership, optional: true

  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS }

  scope :system_views, -> { where(kind: View::KIND_SYSTEM) }
  scope :personal_for, ->(membership) { where(kind: View::KIND_PERSONAL, membership: membership) }
  scope :ordered, -> { order(position: :asc) }

  # Renames applied to existing system views before ensure runs.
  SYSTEM_VIEW_RENAMES = { "Assigned to me" => "Inbox" }.freeze

  def self.ensure_system_views(organization)
    # Apply renames first so find_or_create_by picks up the renamed record.
    SYSTEM_VIEW_RENAMES.each do |old_name, new_name|
      organization.views.where(name: old_name, kind: KIND_SYSTEM).update_all(name: new_name)
    end

    existing = organization.views.where(kind: KIND_SYSTEM).index_by(&:name)
    SYSTEM_VIEWS.each_with_index do |view_data, index|
      view = existing[view_data[:name]] || organization.views.create!(name: view_data[:name], kind: KIND_SYSTEM)
      # Self-heal: keep system views in sync with the canonical definition so
      # filter/icon/order corrections reach already-seeded orgs. System views are
      # not user-editable (views_controller only mutates personal views), so this
      # never clobbers customization.
      desired = { icon: view_data[:icon], filters: view_data[:filters], position: index }
      view.update!(desired) if view.icon != desired[:icon] || view.filters != desired[:filters] || view.position != desired[:position]
    end
  end
end
