module Disk
  # A public link to a file or folder (docs/plans/disk-build.md sections 4 and
  # 6). The token is handed out once and stored only as its SHA-256. An
  # unsealed link's optional password is a bcrypt hash in
  # password_verifier_digest. A sealed link (build guide 6.9) is to one
  # version of one sealed file: kdf_version, kdf_salt and wrapped_payload come
  # from the sealing client, and password_verifier_digest is the SHA-256 of
  # the client's verifier. wrap_key_sealed stays unused.
  class Link < ApplicationRecord
    key_prefix "dln"

    PASSWORD_MAX_BYTES = 72 # bcrypt reads no further
    UNLOCK_TTL = 1.hour
    KDF_VERSION = 1
    SALT_BYTES = 16

    belongs_to :organization
    belongs_to :node, class_name: "Disk::Node"
    belongs_to :version, class_name: "Disk::Version", optional: true
    belongs_to :created_by, class_name: "Membership", foreign_key: :created_by_membership_id, optional: true

    scope :active, -> { where(revoked_at: nil) }

    def self.digest(token) = Digest::SHA256.hexdigest(token.to_s)
    # 22 URL-safe characters, about 131 bits.
    def self.new_token = SecureRandom.alphanumeric(22)

    def password? = password_verifier_digest.present?
    def sealed? = kdf_version.present?
    def self.verifier_digest(raw) = Digest::SHA256.hexdigest(raw)
    def revoked? = revoked_at.present?
    def expired? = expires_at.present? && expires_at <= Time.current

    def password=(value)
      self.password_verifier_digest = value.present? ? BCrypt::Password.create(value) : nil
    end

    # Unsealed: the password. Sealed: the client's verifier, base64.
    def password_matches?(value)
      return false unless password?
      return BCrypt::Password.new(password_verifier_digest).is_password?(value.to_s) unless sealed?

      raw = Base64.strict_decode64(value.to_s)
      ActiveSupport::SecurityUtils.secure_compare(self.class.verifier_digest(raw), password_verifier_digest)
    rescue ArgumentError
      false
    end

    # What a visitor sends back after unlocking, so the password is checked once.
    def unlock_token = self.class.unlocks.generate(id, expires_in: UNLOCK_TTL)
    def unlocked_by?(token) = !password? || (token.present? && self.class.unlocks.verified(token) == id)
    def self.unlocks = Rails.application.message_verifier("disk/link/unlock")

    # The link answers only while it is live, its node and share are live, and
    # the org can still read Disk (its plan, or the read-only month after a
    # downgrade) with links on. Anything else is one identical 404.
    def resolvable?
      org = organization
      !revoked? && !expired? && !node.trashed? && !node.share&.trashed? &&
        org.disk_links_enabled && org.disk_readable? && !org.suspended?
    end

    # Live, unsealed files and folders this link reaches: the node and, for a
    # folder, everything beneath it. Pages are not served through links. A
    # sealed link reaches its one file.
    def reachable
      return Disk::Node.where(id: node_id).live if sealed?

      Disk::Node.subtree(node_id, skip_trash_roots: true).live.where(sealed: false)
        .where.not(kind: Disk::Node::KIND_PAGE)
    end
  end
end
