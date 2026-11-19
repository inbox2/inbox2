# Disk: file storage (docs/plans/disk-build.md). Models live under Disk:: and
# map to the disk_* tables.
module Disk
  def self.table_name_prefix = "disk_"

  # Roles, lowest first. Shared by share memberships, grants and Disk::Access.
  ROLE_VIEW = "view".freeze
  ROLE_EDIT = "edit".freeze
  ROLE_MANAGE = "manage".freeze
  ROLES = [ROLE_VIEW, ROLE_EDIT, ROLE_MANAGE].freeze

  # Deleted items and deleted shares are kept this long, then purged.
  TRASH_DAYS = 30

  def self.role_rank(role) = ROLES.index(role) || -1

  # How Disk names a member, or the agent acting through an agent membership.
  def self.display_name(membership)
    return membership.agents.first&.name || "Agent" if membership.agent?

    membership.user.display_name.presence || membership.user.username
  end

  # A Disk operation the API refuses, with the HTTP status to answer with and
  # any extra fields for the error body (a quota code, the current key epoch).
  class Refused < StandardError
    attr_reader :status, :extra

    def initialize(message, status: 422, **extra)
      super(message)
      @status = status
      @extra = extra
    end
  end
end
