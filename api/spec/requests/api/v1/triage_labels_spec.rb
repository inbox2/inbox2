require "rails_helper"

# docs/Triage.md — Jev action labels: built-ins + org custom.
RSpec.describe "Api::V1::TriageLabels", type: :request do
  let(:owner) { create(:user, username: "labelowner") }
  let(:org) { create(:organization, owner: owner, domain: "labels.com") }
  let!(:owner_membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }
  let(:member) do
    create(:user, username: "labelmember").tap do |u|
      create(:membership, user: u, organization: org, role: "member", status: "active")
    end
  end
  let(:base) { "/api/v1/orgs/#{org.key}/triage-labels" }
  let(:custom_params) do
    { slug: "legal_review", name: "Legal review",
      description: "Contracts, NDAs or terms that legal must read before anyone signs",
      not_for: "Signed contracts that only need filing", color: "#AA3355" }
  end

  describe "GET" do
    context "positive" do
      it "seeds the built-ins in contract order with tlb_ ids" do
        get base, headers: auth_headers(member)
        expect(response).to have_http_status(:ok)
        labels = response.parsed_body["triage_labels"]
        expect(labels.map { |l| l["slug"] }).to eq(TriageLabel::BUILTIN_SLUGS)
        expect(labels.first.keys).to match_array(%w[id slug name description not_for color builtin enabled position])
        expect(labels).to all(include("builtin" => true, "enabled" => true))
        expect(labels.first["id"]).to start_with("tlb_")
      end

      it "is idempotent" do
        2.times { get base, headers: headers }
        expect(org.triage_labels.count).to eq(TriageLabel::BUILTIN.size)
      end

      it "adds built-ins from a later release after an existing org's labels, refreshing unedited old texts" do
        legacy = TriageLabel::LEGACY_TEXTS.to_h { |l| [l[:slug], l] }
        TriageLabel::BUILTIN.first(8).each_with_index do |data, i|
          org.triage_labels.create!(data.merge(legacy.fetch(data[:slug], {})).merge(builtin: true, position: i))
        end
        org.triage_labels.find_by!(slug: "action_required").update!(description: "Our own wording")
        org.triage_labels.create!(custom_params.merge(position: 8))

        get base, headers: headers
        slugs = response.parsed_body["triage_labels"].map { |l| l["slug"] }
        expect(slugs).to eq(TriageLabel::BUILTIN_SLUGS.first(8) + ["legal_review"] + TriageLabel::BUILTIN_SLUGS.last(5))
        current = TriageLabel::BUILTIN.find { |l| l[:slug] == "fyi" }
        expect(org.triage_labels.find_by!(slug: "fyi")).to have_attributes(current.slice(:description, :not_for))
        expect(org.triage_labels.find_by!(slug: "action_required").description).to eq("Our own wording")
      end
    end

    context "negative" do
      it "404s for a non-member (tenant isolation)" do
        get base, headers: auth_headers(create(:user, username: "labeloutsider"))
        expect(response).to have_http_status(:not_found)
      end

      it "401s without auth" do
        get base
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe "POST" do
    context "positive" do
      it "creates a custom label after the built-ins" do
        post base, params: custom_params, headers: headers, as: :json
        expect(response).to have_http_status(:created)
        body = response.parsed_body["triage_label"]
        expect(body).to include("slug" => "legal_review", "builtin" => false, "enabled" => true, "color" => "#AA3355")
        expect(body["position"]).to be > org.triage_labels.find_by!(slug: "resolved").position
      end

      it "derives the slug from the name when omitted, and never lets a client set builtin" do
        post base, params: custom_params.except(:slug).merge(builtin: true), headers: headers, as: :json
        expect(response).to have_http_status(:created)
        expect(response.parsed_body["triage_label"]).to include("slug" => "legal_review", "builtin" => false)
      end
    end

    context "negative" do
      it "403s for a plain member" do
        post base, params: custom_params, headers: auth_headers(member), as: :json
        expect(response).to have_http_status(:forbidden)
      end

      it "rejects a built-in or reserved slug" do
        %w[fyi no_match].each do |slug|
          post base, params: custom_params.merge(slug: slug), headers: headers, as: :json
          expect(response).to have_http_status(:unprocessable_content)
          expect(response.parsed_body["errors"].first["message"]).to match(/reserved|taken/)
        end
      end

      it "rejects a malformed slug and a missing description" do
        post base, params: custom_params.merge(slug: "Legal-Review!"), headers: headers, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        post base, params: custom_params.merge(description: ""), headers: headers, as: :json
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  describe "PATCH" do
    before { TriageLabel.ensure_defaults(org) }

    context "positive" do
      it "edits a built-in's description/not_for and disables it" do
        label = org.triage_labels.find_by!(slug: "resolved")
        patch "#{base}/#{label.key}", params: { description: "Done and dusted", not_for: "x", enabled: false },
                                      headers: headers, as: :json
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["triage_label"]).to include("description" => "Done and dusted", "enabled" => false)
      end
    end

    context "negative" do
      it "refuses to disable fyi" do
        label = org.triage_labels.find_by!(slug: "fyi")
        patch "#{base}/#{label.key}", params: { enabled: false }, headers: headers, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(label.reload.enabled).to be(true)
      end

      it "refuses to change a built-in slug" do
        label = org.triage_labels.find_by!(slug: "scheduling")
        patch "#{base}/#{label.key}", params: { slug: "meetings" }, headers: headers, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(label.reload.slug).to eq("scheduling")
      end

      it "403s for a plain member" do
        label = org.triage_labels.find_by!(slug: "resolved")
        patch "#{base}/#{label.key}", params: { name: "x" }, headers: auth_headers(member), as: :json
        expect(response).to have_http_status(:forbidden)
      end

      it "404s for another org's label" do
        other = create(:organization, owner: owner, domain: "otherlabels.com")
        foreign = TriageLabel.ensure_defaults(other).first
        patch "#{base}/#{foreign.key}", params: { name: "x" }, headers: headers, as: :json
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "DELETE" do
    before { TriageLabel.ensure_defaults(org) }

    it "deletes a custom label" do
      label = org.triage_labels.create!(custom_params)
      delete "#{base}/#{label.key}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(TriageLabel.exists?(label.id)).to be(false)
    end

    it "refuses to delete a built-in" do
      label = org.triage_labels.find_by!(slug: "needs_answer")
      delete "#{base}/#{label.key}", headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(TriageLabel.exists?(label.id)).to be(true)
    end

    it "403s for a plain member" do
      label = org.triage_labels.create!(custom_params)
      delete "#{base}/#{label.key}", headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "goes away with the org (built-ins included)" do
    TriageLabel.ensure_defaults(org)
    expect { org.destroy! }.to change(TriageLabel, :count).by(-TriageLabel::BUILTIN.size)
  end
end
