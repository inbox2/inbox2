require "rails_helper"

# Spec F9: save a mail attachment to Disk, attach a Disk file to a draft (MX mail).
RSpec.describe "Disk mail integration", type: :request do
  include_context "disk org"

  # The attachments store, in memory: stream and upload as S3StorageService does.
  let(:mail_store) do
    Class.new do
      attr_reader :objects

      def initialize = @objects = {}
      def stream(key) = yield(objects.fetch(key))

      def upload(io, filename:, content_type:, organization_key:)
        "#{organization_key}/#{SecureRandom.hex(4)}/#{filename}".tap { |k| objects[k] = io.read }
      end
    end.new
  end
  let(:owner_h) { auth_headers(owner_user) }
  let(:share) { make_share("Marketing") }
  let(:conversation) { create(:conversation, organization: org) }
  let(:message) { create(:message, conversation: conversation, from_address: "Ann <ann@acme.test>", subject: "Q3 numbers") }
  let(:attachment) do
    mail_store.objects["att/1"] = "%PDF-q3"
    create(:attachment, message: message, filename: "q3.pdf", size_bytes: 7, storage_key: "att/1")
  end

  before { allow(S3StorageService).to receive(:new).and_return(mail_store) }

  def save_path(msg = message, att = attachment) = "/api/v1/orgs/#{org.key}/messages/#{msg.key}/attachments/#{att.key}/save-to-disk"

  describe "POST /messages/:id/attachments/:attachment_id/save-to-disk" do
    it "saves the file into the folder with the sender and subject in its details" do
      post save_path, params: { parent_id: share.root_node.key }, headers: owner_h, as: :json
      expect(response).to have_http_status(:created)
      node = Disk::Node.find_by!(key: response.parsed_body["node"]["id"])
      expect(node).to have_attributes(name: "q3.pdf", mime: "application/pdf", size_bytes: 7)
      expect(storage.read_range(node.current_version.storage_key, 0, 7)).to eq("%PDF-q3")
      expect(node.current_version.sha256).to eq(Digest::SHA256.hexdigest("%PDF-q3"))
      expect(org.reload.disk_bytes_used).to eq(7)

      get disk_path("/nodes/#{node.short_id}"), headers: owner_h
      expect(response.parsed_body["node"]["origin"]).to eq("from" => "Ann <ann@acme.test>", "subject" => "Q3 numbers",
                                                            "message" => message.key)
      post save_path, params: { parent_id: share.root_node.key }, headers: owner_h, as: :json
      expect(response).to have_http_status(:conflict)
      post save_path, params: { parent_id: share.root_node.key, on_conflict: "replace" }, headers: owner_h, as: :json
      expect(node.reload.versions.count).to eq(2)
    end

    it "refuses sealed mail, a folder the member cannot write to, and over quota" do
      attachment.update_columns(sealed_filename: "x")
      post save_path, params: { parent_id: share.root_node.key }, headers: owner_h, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"].first["message"]).to match(/sealing client/)
      attachment.update_columns(sealed_filename: nil)

      viewer_share = make_share("Read only", openness: Disk::Share::OPENNESS_ORG, org_role: Disk::ROLE_VIEW)
      post save_path, params: { parent_id: viewer_share.root_node.key }, headers: auth_headers(member_user), as: :json
      expect(response).to have_http_status(:forbidden)

      org.update!(disk_quota_override_gb: 0)
      post save_path, params: { parent_id: share.root_node.key }, headers: owner_h, as: :json
      expect(response.parsed_body["code"]).to eq("disk_quota_exceeded")
      expect(org.reload.disk_bytes_reserved).to eq(0)
    end

    it "is not found across tenants" do
      theirs = create(:message, conversation: create(:conversation, organization: outsider_org))
      post save_path(theirs, create(:attachment, message: theirs)), params: { parent_id: share.root_node.key },
                                                                    headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
      post save_path, params: { parent_id: foreign_node.key }, headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /messages/:id/attachments/from-disk" do
    let(:draft) { create(:message, conversation: conversation, is_draft: true, is_inbound: false, owner_membership_id: owner.id) }
    let(:file) do
      make_folder(share.root_node, "deck.pdf").tap do |n|
        n.update!(kind: Disk::Node::KIND_FILE, mime: "application/pdf")
        key = Disk::Storage.new_key(org)
        storage.put_bytes(key, "%PDF-deck")
        n.add_version!(author: owner, storage_key: key, size_bytes: 9)
      end
    end

    def attach_path(msg = draft) = "/api/v1/orgs/#{org.key}/messages/#{msg.key}/attachments/from-disk"

    it "copies the file into the mail store as an attachment of the draft" do
      post attach_path, params: { node_id: file.short_id }, headers: owner_h, as: :json
      expect(response).to have_http_status(:created)
      att = Attachment.find_by!(key: response.parsed_body["attachment"]["id"])
      expect(att).to have_attributes(message_id: draft.id, filename: "deck.pdf", size_bytes: 9, content_type: "application/pdf")
      expect(mail_store.objects[att.storage_key]).to eq("%PDF-deck")
    end

    it "refuses a sent message, a file over the mail limit, a sealed file and another org's file" do
      post attach_path(message), params: { node_id: file.key }, headers: owner_h, as: :json
      expect(response).to have_http_status(:unprocessable_content)

      # The link is offered from the send cap (25 MB), not from the plan's larger limit.
      cap = OutboundMailPublisher::MAX_ATTACHMENT_BYTES
      file.update_columns(size_bytes: cap + 1)
      post attach_path, params: { node_id: file.key }, headers: owner_h, as: :json
      expect(response.parsed_body).to include("code" => "disk_attachment_too_large", "limit_bytes" => cap)

      # ... and what the draft already carries counts toward it.
      file.update_columns(size_bytes: cap - 10)
      Attachment.create!(organization: org, message: draft, filename: "a.bin", size_bytes: 11, content_type: "application/octet-stream", storage_key: "k")
      post attach_path, params: { node_id: file.key }, headers: owner_h, as: :json
      expect(response.parsed_body).to include("code" => "disk_attachment_too_large", "limit_bytes" => cap)
      draft.attachments.destroy_all

      post attach_path, params: { node_id: make_sealed_file(make_sealed_share.root_node, size: 32).key }, headers: owner_h, as: :json
      expect(response.parsed_body["errors"].first["message"]).to match(/sealing client/)

      post attach_path, params: { node_id: foreign_node.key }, headers: owner_h, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end
end
