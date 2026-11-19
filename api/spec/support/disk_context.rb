# A paid org with Disk, its owner, a plain member and a second org for
# cross-tenant checks. Helpers build shares and folders directly.
RSpec.shared_context "disk org" do
  include_context "fake disk storage"

  let(:owner_user) { create(:user, display_name: "Olive Owner") }
  let(:org) { create(:organization, owner: owner_user) }
  let!(:owner) { create(:membership, user: owner_user, organization: org, role: "owner") }
  let(:member_user) { create(:user, display_name: "Mo Member") }
  let!(:member) { create(:membership, user: member_user, organization: org, role: "member") }
  let(:other_user) { create(:user, display_name: "Ola Other") }
  let!(:other) { create(:membership, user: other_user, organization: org, role: "member") }
  let(:outsider_org) { create(:organization) }

  before do
    create(:subscription, organization: org, plan: Plan.paid)
    create(:subscription, organization: outsider_org, plan: Plan.paid)
  end

  def disk_path(path = "") = "/api/v1/orgs/#{org.key}/disk#{path}"

  def make_share(name = "Marketing", organization: org, **attrs)
    Disk::Share.create_with_root!(organization: organization, name: name, **attrs)
  end

  # The person's C:\ root: in their personal workspace, its membership the custodian (2026-10-07).
  def c_root(membership) = Disk::Node.c_root_for(membership)

  def make_folder(parent, name, by: nil, **attrs)
    Disk::Node.create!(organization_id: parent.organization_id, share_id: parent.share_id,
                       custodian_membership_id: parent.custodian_membership_id, parent: parent,
                       kind: Disk::Node::KIND_FOLDER, name: name, created_by: by, modified_by: by,
                       content_modified_at: Time.current, **attrs)
  end

  def make_file(parent, name, mime:, size: 1, **attrs)
    make_folder(parent, name, **attrs).tap { |n| n.update!(kind: Disk::Node::KIND_FILE, mime: mime, size_bytes: size) }
  end

  # A file with a stored current version of `size` bytes, counted in the quota
  # as an upload would. Pass `versions:` for older ones first.
  def make_stored_file(parent, name, size:, versions: [], by: nil, mime: "application/pdf")
    node = make_folder(parent, name, by: by).tap { |n| n.update!(kind: Disk::Node::KIND_FILE, mime: mime) }
    (versions + [size]).each do |s|
      key = Disk::Storage.new_key(parent.organization)
      storage.put(key, s)
      Disk::Node.transaction do
        node.add_version!(author: by, storage_key: key, size_bytes: s)
        Disk::Quota.move!(parent.organization_id, used: s)
      end
    end
    node.reload
  end

  # ── Sealing (build guide 6). Fixture ciphertext: random bytes in the
  # envelope's shape, never readable, never containing a test's plaintext.
  def envelope(size = 64) = "\x01".b + SecureRandom.random_bytes(size - 1)
  def b64(bytes) = Base64.strict_encode64(bytes)
  def sealed_key = SecureRandom.random_bytes(Disk::KeyGrant::SEALED_KEY_BYTES)
  def new_id(prefix) = "#{prefix}_#{Nanoid.generate(size: 21)}"

  def give_identity(*memberships)
    memberships.each do |m|
      UserKey.find_or_create_by!(user: m.user) { |k| k.assign_attributes(public_key: b64(SecureRandom.random_bytes(32)), encrypted_private_key: "x") }
    end
  end

  def key_grant!(root, membership, epoch: root.scope_epoch)
    Disk::KeyGrant.create!(organization_id: root.organization_id, scope_node: root, membership: membership,
                           epoch: epoch, sealed_key: sealed_key)
  end

  # A sealed share at epoch 1 whose holders ({ membership => role }) hold its key.
  def make_sealed_share(name = "Vault", holders: { owner => "manage" })
    share = make_share(name)
    root = share.root_node
    root.update!(sealed: true, seal_scope_node_id: root.id, scope_epoch: 1)
    Disk::ScopeEpoch.create!(organization: org, scope_node: root, epoch: 1)
    holders.each do |m, role|
      Disk::ShareMembership.create!(organization: org, share: share, membership: m, role: role)
      key_grant!(root, m)
    end
    share
  end

  # A sealed folder on membership's C:\ at epoch 1, its custodian holding the key.
  def make_sealed_folder(membership, parent: c_root(membership))
    node = Disk::Node.create!(organization_id: parent.organization_id, custodian_membership_id: parent.custodian_membership_id,
                              parent: parent, kind: Disk::Node::KIND_FOLDER,
                              sealed: true, metadata_ciphertext: envelope, key_epoch: 1, scope_epoch: 1)
    node.update!(seal_scope_node_id: node.id)
    Disk::ScopeEpoch.create!(organization_id: parent.organization_id, scope_node: node, epoch: 1)
    key_grant!(node, membership.as_holder(node))
    node
  end

  def scope_of(node) = Disk::Node.find(node.seal_scope_node_id)

  def make_sealed_node(parent, kind: Disk::Node::KIND_FOLDER)
    Disk::Node.create!(organization_id: parent.organization_id, share_id: parent.share_id,
                       custodian_membership_id: parent.custodian_membership_id, parent: parent, kind: kind,
                       sealed: true, seal_scope_node_id: parent.seal_scope_node_id, metadata_ciphertext: envelope,
                       key_epoch: scope_of(parent).scope_epoch, content_modified_at: Time.current)
  end

  # A sealed file with one stored version of ciphertext `size` bytes.
  def make_sealed_file(parent, size: 1.megabyte + 16)
    node = make_sealed_node(parent, kind: Disk::Node::KIND_FILE)
    key = Disk::Storage.new_key(parent.organization)
    storage.put_bytes(key, SecureRandom.random_bytes(size))
    Disk::Node.transaction do
      node.add_version!(author: nil, storage_key: key, size_bytes: size, chunk_bytes: 1.megabyte,
                        key_epoch: node.key_epoch, wrapped_key: envelope, manifest_ciphertext: envelope(120))
      Disk::Quota.move!(parent.organization_id, used: size)
    end
    node.reload
  end

  # A share and a node in another org, for cross-tenant 404s.
  def foreign_share = @foreign_share ||= make_share("Theirs", organization: outsider_org)
  def foreign_node = @foreign_node ||= make_folder(foreign_share.root_node, "Secret")
end
