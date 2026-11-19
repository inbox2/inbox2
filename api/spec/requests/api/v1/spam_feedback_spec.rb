require "rails_helper"

RSpec.describe "Api::V1::Conversations spam-feedback", type: :request do
  include ActiveJob::TestHelper

  let(:owner) { create(:user, username: "spamowner") }
  let(:org) { create(:organization, owner: owner, domain: "spam.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  # spec 11.1.3, A15.2
  describe "POST /api/v1/orgs/:org_id/conversations/:id/spam-feedback" do
    let!(:conv) { create(:conversation, organization: org, status: "open") }

    it "marks as spam" do
      post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/spam-feedback",
           params: { is_spam: true },
           headers: headers
      expect(response).to have_http_status(:ok)
      expect(conv.reload.status).to eq("spam")
    end

    it "marks as not-spam (moves back to open)" do
      conv.update!(status: "spam")
      post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/spam-feedback",
           params: { is_spam: false },
           headers: headers
      expect(response).to have_http_status(:ok)
      expect(conv.reload.status).to eq("open")
    end

    # Not-spam re-runs the triage that the spam verdict skipped at ingest.
    describe "not-spam re-triage" do
      before do
        org.update!(plan: create(:plan, ai_triage: true, tier: Plan::TIER_PAID))
        conv.update!(status: "spam")
        allow(SpaceClassifier).to receive(:enabled?).and_return(true)
      end

      it "enqueues ClassifySpaceJob for an unlabeled plaintext thread" do
        create(:message, conversation: conv, organization: org, is_inbound: true)

        expect {
          post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/spam-feedback",
               params: { is_spam: false }, headers: headers
        }.to have_enqueued_job(ClassifySpaceJob).with(conv.id)
      end

      it "does not enqueue for a sealed thread (excerpt gone; client labels it)" do
        create(:message, conversation: conv, organization: org, is_inbound: true,
          encryption_scheme: Message::ENCRYPTION_SCHEME_SEALED_BOX_V1,
          from_address: nil, subject: nil, body_plain: nil, body_html: nil,
          message_id_header: nil, sealed_dek: "blob", body_ciphertext: "ct", header_ciphertext: "ct")

        expect {
          post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/spam-feedback",
               params: { is_spam: false }, headers: headers
        }.not_to have_enqueued_job(ClassifySpaceJob)
      end

      it "does not enqueue when the thread was already triaged" do
        conv.update!(triage_label: TriageLabel::FYI)
        create(:message, conversation: conv, organization: org, is_inbound: true)

        expect {
          post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/spam-feedback",
               params: { is_spam: false }, headers: headers
        }.not_to have_enqueued_job(ClassifySpaceJob)
      end
    end

    # Sealed rows have no plaintext — Bayes training is skipped entirely.
    it "does not train Rspamd on sealed feedback" do
      conv.update!(status: "open")
      create(:message, conversation: conv, organization: org, is_inbound: true,
        encryption_scheme: Message::ENCRYPTION_SCHEME_SEALED_BOX_V1,
        from_address: nil, subject: nil, body_plain: nil, body_html: nil,
        message_id_header: nil, sealed_dek: "blob", body_ciphertext: "ct", header_ciphertext: "ct")

      expect(RspamdClient).not_to receive(:new)
      perform_enqueued_jobs do
        post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/spam-feedback",
             params: { is_spam: true }, headers: headers
      end
      expect(response).to have_http_status(:ok)
    end
  end
end
