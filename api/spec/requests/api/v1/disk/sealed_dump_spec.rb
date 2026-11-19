require "rails_helper"

# Spec F7 (first box) and F7b ("no sealed plaintext"): after sealed content goes
# through the API the way the web client sends it, a dump of every table, the
# bucket, the request log and the queued emails hold no name, type or content.
# A marker sent through the unsealed path is the control that proves the grep
# finds what is there.
RSpec.describe "Disk sealed content leaves no plaintext", type: :request do
  include_context "disk org"
  include ActiveJob::TestHelper

  let(:marker) { "Q3-board-SECRET-#{SecureRandom.hex(4)}" }
  let(:control) { "CONTROL-#{SecureRandom.hex(4)}" }
  let(:owner_h) { auth_headers(owner_user) }
  let(:scope_key) { RbNaCl::Random.random_bytes(32) }

  before { give_identity(owner, member) }

  def json = response.parsed_body

  # ENV (build guide 6.3) with real XChaCha20-Poly1305: what a client stores.
  def seal(plaintext, ad = "disk/test")
    nonce = RbNaCl::Random.random_bytes(24)
    "\x01".b + nonce + RbNaCl::AEAD::XChaCha20Poly1305IETF.new(scope_key).encrypt(nonce, plaintext, ad)
  end

  def meta = b64(seal({ mime: "application/pdf", name: "#{marker}.pdf" }.to_json))

  # Every row of every table, as pg_dump --data-only would write it, read
  # inside the test's transaction so uncommitted rows are included.
  def table_dump
    conn = ActiveRecord::Base.connection
    tables = conn.select_values("SELECT tablename FROM pg_tables WHERE schemaname = 'public'")
    raw = conn.raw_connection
    tables.map do |t|
      out = +""
      raw.copy_data("COPY #{raw.quote_ident(t)} TO STDOUT") { while (row = raw.get_copy_data) do out << row end }
      out
    end.join.b
  end

  def bucket_dump = storage.objects.map { |k, o| k.b + (o[:body] || "".b) }.join

  def upload(parent_key, body:, sealed: true, name: nil)
    size = body.bytesize
    params = sealed ? { sealed: true, chunk_bytes: 1.megabyte, key_epoch: 1, id: new_id("dnd"), metadata_ciphertext: meta } : { name: name }
    post disk_path("/uploads"), params: { parent_id: parent_key, size_bytes: size, **params }, headers: owner_h, as: :json
    up = json["upload"]
    post disk_path("/uploads/#{up['id']}/parts"), params: { numbers: [1] }, headers: owner_h, as: :json
    storage.put_part(Disk::Upload.find_by!(key: up["id"]).multipart_upload_id, 1, body)
    done = sealed ? { wrapped_key: b64(seal(scope_key)), manifest_ciphertext: b64(seal({ size: size }.to_json)) } : {}
    post disk_path("/uploads/#{up['id']}/complete"), params: done, headers: owner_h, as: :json
    json
  end

  it "keeps names, types and content out of the database, the bucket, the log and email" do
    log = StringIO.new
    logger = ActiveSupport::Logger.new(log)
    Rails.logger.broadcast_to(logger)
    key_material = []

    # A sealed share and a sealed C:\ folder, the way the client makes them.
    grant = RbNaCl::Random.random_bytes(80).tap { |k| key_material << k }
    post disk_path("/shares"), params: { name: "Board", sealed: true, sealed_key: b64(grant) }, headers: owner_h, as: :json
    root = Disk::Share.find_by!(key: json["share"]["id"]).root_node
    post disk_path("/nodes"), params: { parent_id: c_root(owner).key, kind: "folder", sealed: true, id: new_id("dnd"),
                                        metadata_ciphertext: meta, key_epoch: 1, sealed_key: b64(RbNaCl::Random.random_bytes(80)) },
                              headers: owner_h, as: :json
    # A sealed file whose content mentions the marker, a sealed rename, a sealed page.
    content = "#{marker} quarterly numbers"
    file = upload(root.key, body: seal(content))["node"]
    expect(file).to include("name" => nil, "mime" => nil)
    patch disk_path("/nodes/#{file['id']}"), params: { metadata_ciphertext: meta, key_epoch: 1 }, headers: owner_h, as: :json
    page_id = new_id("dnd")
    post disk_path("/nodes"), params: { parent_id: root.key, kind: "page", id: page_id, metadata_ciphertext: meta, key_epoch: 1 },
                              headers: owner_h, as: :json
    post disk_path("/pages/#{page_id}/updates"), params: { update: b64(seal("# #{marker}")), epoch: 1, seq: 1 }, headers: owner_h, as: :json
    put disk_path("/pages/#{page_id}"), params: { sealed_snapshot: b64(seal("# #{marker} agenda")), epoch: 1, seq: 1 }, headers: owner_h, as: :json
    # A key holder added (notification and email), a sealed link with a password.
    added = RbNaCl::Random.random_bytes(80).tap { |k| key_material << k }
    put disk_path("/shares/#{root.share.key}/members/#{member.key}"), params: { role: "edit", sealed_key: b64(added), epoch: 1 },
                                                                     headers: owner_h, as: :json
    expect(response).to have_http_status(:ok)
    verifier = RbNaCl::Random.random_bytes(32).tap { |k| key_material << k }
    post disk_path("/nodes/#{file['id']}/links"),
         params: { id: new_id("dln"), version_id: Disk::Node.find_by!(key: file["id"]).current_version.key,
                   kdf_salt: b64(RbNaCl::Random.random_bytes(16)), wrapped_payload: b64(seal({ name: marker }.to_json)),
                   password_verifier: b64(verifier) }, headers: owner_h, as: :json
    token = json["link"]["token"]
    expect(json["link"]["url"]).not_to include(marker)
    post "/api/v1/disk/links/#{token}/unlock", params: { verifier: b64(verifier) }, as: :json
    expect(response).to have_http_status(:ok)

    # The control: the same marker through the unsealed path is found everywhere.
    upload(c_root(owner).key, body: "#{control} body", sealed: false, name: "#{control}.pdf")

    Rails.logger.stop_broadcasting_to(logger)
    rows = table_dump
    bucket = bucket_dump
    emails = enqueued_jobs.map { |j| j[:args].to_json }.join

    expect(rows).to include(control.b)
    expect(bucket).to include(control.b)
    expect(log.string).to include(control)
    expect(rows).not_to include(marker.b)
    expect(bucket).not_to include(marker.b)
    expect(log.string).not_to include(marker)
    expect(emails).not_to include(marker)
    expect(emails).to include("Board") # the share's own name is administrative, not sealed content
    expect(Disk::Event.where(node_id: Disk::Node.where(sealed: true).select(:id)).pluck(:detail).to_json).not_to include("name")
    key_material.each { |k| expect(log.string).not_to include(b64(k)) }
    expect(Disk::Storage.current.objects.keys).to all(match(%r{\A#{org.key}/\h{32}(\.\w+)?\z}))
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end
end
