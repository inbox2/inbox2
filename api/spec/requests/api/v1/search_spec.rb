require "rails_helper"

RSpec.describe "Api::V1::Search", type: :request do
  let(:owner) { create(:user, username: "searchowner") }
  let(:org) { create(:organization, owner: owner, domain: "search.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  # spec 6.3.1-6.3.3, A10.6
  describe "GET /api/v1/orgs/:org_id/search" do
    before do
      create(:conversation, organization: org, subject: "Invoice for January", from_address: "billing@example.com")
      create(:conversation, organization: org, subject: "Support request", from_address: "customer@example.com")
    end

    it "searches conversations by keyword" do
      get "/api/v1/orgs/#{org.key}/search", params: { q: "invoice" }, headers: headers
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["conversations"].length).to eq(1)
      expect(body["conversations"].first["subject"]).to include("Invoice")
    end

    it "ANDs bare terms (all must match)" do
      get "/api/v1/orgs/#{org.key}/search", params: { q: "invoice support" }, headers: headers
      expect(response).to have_http_status(:ok)
      # No single conversation contains both words, so AND yields nothing.
      expect(response.parsed_body["conversations"]).to eq([])
    end

    it "supports the OR operator" do
      get "/api/v1/orgs/#{org.key}/search", params: { q: "invoice OR support" }, headers: headers
      expect(response).to have_http_status(:ok)
      subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
      expect(subjects).to contain_exactly("Invoice for January", "Support request")
    end

    it "skips trashed and spam conversations, but keeps archived ones" do
      create(:conversation, organization: org, subject: "Invoice deleted", from_address: "billing@example.com", status: Conversation::STATUS_TRASH)
      create(:conversation, organization: org, subject: "Invoice junk", from_address: "billing@example.com", status: Conversation::STATUS_SPAM)
      create(:conversation, organization: org, subject: "Invoice filed", from_address: "billing@example.com", status: Conversation::STATUS_ARCHIVED)

      get "/api/v1/orgs/#{org.key}/search", params: { q: "invoice" }, headers: headers
      expect(response).to have_http_status(:ok)
      subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
      expect(subjects).to contain_exactly("Invoice for January", "Invoice filed")
    end

    it "includes trashed and spam conversations for in=anywhere" do
      create(:conversation, organization: org, subject: "Invoice deleted", from_address: "billing@example.com", status: Conversation::STATUS_TRASH)

      get "/api/v1/orgs/#{org.key}/search", params: { q: "invoice", in: "anywhere" }, headers: headers
      expect(response).to have_http_status(:ok)
      subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
      expect(subjects).to contain_exactly("Invoice for January", "Invoice deleted")
    end

    it "narrows to one folder for in=trash" do
      create(:conversation, organization: org, subject: "Invoice deleted", from_address: "billing@example.com", status: Conversation::STATUS_TRASH)

      get "/api/v1/orgs/#{org.key}/search", params: { q: "invoice", in: "trash" }, headers: headers
      subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
      expect(subjects).to contain_exactly("Invoice deleted")
    end

    it "returns empty results for no match" do
      get "/api/v1/orgs/#{org.key}/search", params: { q: "nonexistent" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["conversations"]).to eq([])
    end

    it "matches conversations by attachment filename" do
      conv = create(:conversation, organization: org, subject: "FYI", from_address: "ops@example.com")
      msg = create(:message, conversation: conv, organization: org)
      create(:attachment, message: msg, organization: org, filename: "Quarterly_Budget.xlsx")

      # "budget" appears only in the filename — the subject/snippet don't mention
      # it — so a hit proves filenames are searched (and normalized: the '_' and
      # '.' are split so "budget" matches inside "Quarterly_Budget.xlsx").
      get "/api/v1/orgs/#{org.key}/search", params: { q: "budget" }, headers: headers
      expect(response).to have_http_status(:ok)
      subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
      expect(subjects).to contain_exactly("FYI")
    end

    it "matches a word that only appears in a message body" do
      conv = create(:conversation, organization: org, subject: "FYI", from_address: "ops@example.com")
      create(:message, conversation: conv, organization: org, body_plain: "Graag de suppletie voor vrijdag")

      get "/api/v1/orgs/#{org.key}/search", params: { q: "suppletie" }, headers: headers
      expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("FYI")
    end

    # The Imran case (2026-10-07): "btw" and "sizio" in the body, "nummer" only
    # inside the attached PDF. Body and attachment text are one document, so all
    # three words match the one message.
    it "ANDs words across a message body and its attachment text" do
      conv = create(:conversation, organization: org, subject: "BTW Q3 2025", from_address: "imran@example.nl")
      msg = create(:message, conversation: conv, organization: org, body_plain: "Zie bijlage voor Sizio")
      create(:attachment, message: msg, organization: org, filename: "aangifte.pdf", content_text: "Btw-nummer NL827315636B01")

      get "/api/v1/orgs/#{org.key}/search", params: { q: "btw nummer sizio" }, headers: headers
      expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("BTW Q3 2025")
    end

    it "does not match words in a draft" do
      conv = create(:conversation, organization: org, subject: "Shared", from_address: "ops@example.com")
      create(:message, conversation: conv, organization: org, is_draft: true, body_plain: "confidential raise numbers")

      get "/api/v1/orgs/#{org.key}/search", params: { q: "confidential" }, headers: headers
      expect(response.parsed_body["conversations"]).to eq([])
    end

    it "does not index sealed mail" do
      conv = create(:conversation, organization: org, subject: "Sealed", from_address: "ops@example.com")
      msg = create(:message, conversation: conv, organization: org, body_plain: "plaintext leftovers")
      msg.update!(encryption_scheme: Message::ENCRYPTION_SCHEME_SEALED_BOX_V1, from_address: nil)

      expect(msg.reload.search_vector).to be_nil
    end

    it "does not match message bodies from another org (E3)" do
      other_user = create(:user, username: "searchbodyiso")
      other_org = create(:organization, owner: other_user, domain: "searchbodyiso.com")
      other_conv = create(:conversation, organization: other_org, subject: "Other org")
      create(:message, conversation: other_conv, organization: other_org, body_plain: "suppletie")

      get "/api/v1/orgs/#{org.key}/search", params: { q: "suppletie" }, headers: headers
      expect(response.parsed_body["conversations"]).to eq([])
    end

    it "finds a word inside an unsegmented Chinese subject" do
      create(:conversation, organization: org, subject: "您的订单已发货", from_address: "shop@example.cn")

      # Chinese has no word delimiters, so to_tsvector indexes the whole run as
      # ONE token and a tsquery for 订单 can never match — this must fall through
      # to the substring path.
      get "/api/v1/orgs/#{org.key}/search", params: { q: "订单" }, headers: headers
      expect(response).to have_http_status(:ok)
      subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
      expect(subjects).to contain_exactly("您的订单已发货")
    end

    it "finds a Chinese word in a message body and in attachment text" do
      body = create(:conversation, organization: org, subject: "Re: hello", from_address: "a@example.cn")
      create(:message, conversation: body, organization: org, body_plain: "您的订单已发货")
      att = create(:conversation, organization: org, subject: "Files", from_address: "b@example.cn")
      msg = create(:message, conversation: att, organization: org, body_plain: "see attached")
      create(:attachment, message: msg, organization: org, filename: "a.txt", content_text: "发票编号")

      get "/api/v1/orgs/#{org.key}/search", params: { q: "订单" }, headers: headers
      expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("Re: hello")
      get "/api/v1/orgs/#{org.key}/search", params: { q: "发票" }, headers: headers
      expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("Files")
    end

    it "searches a sent message by the text of an attachment moved onto it from its draft" do
      conv = create(:conversation, organization: org, subject: "Contract", from_address: "me@example.com")
      draft = create(:message, conversation: conv, organization: org, is_draft: true, body_plain: "draft")
      sent = create(:message, conversation: conv, organization: org, body_plain: "here it is")
      a = create(:attachment, message: draft, organization: org, filename: "c.txt", content_text: "Zwanenburg clause")
      a.update!(message: sent)

      get "/api/v1/orgs/#{org.key}/search", params: { q: "Zwanenburg" }, headers: headers
      expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("Contract")
    end

    it "matches a non-Latin attachment filename" do
      conv = create(:conversation, organization: org, subject: "مرفق", from_address: "ops@example.sa")
      msg = create(:message, conversation: conv, organization: org)
      create(:attachment, message: msg, organization: org, filename: "الميزانية.pdf")

      # Normalizing filenames with [a-zA-Z0-9] erased every character of this
      # name, indexing it as just "pdf" and making it unsearchable.
      get "/api/v1/orgs/#{org.key}/search", params: { q: "الميزانية" }, headers: headers
      expect(response).to have_http_status(:ok)
      subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
      expect(subjects).to contain_exactly("مرفق")
    end

    it "does not match attachment filenames from another org (E3)" do
      other_user = create(:user, username: "searchattiso")
      other_org = create(:organization, owner: other_user, domain: "searchattiso.com")
      create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")
      other_conv = create(:conversation, organization: other_org, subject: "Other org")
      other_msg = create(:message, conversation: other_conv, organization: other_org)
      create(:attachment, message: other_msg, organization: other_org, filename: "secret_budget.xlsx")

      # Searching our own org must never surface the other org's attachment.
      get "/api/v1/orgs/#{org.key}/search", params: { q: "budget" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["conversations"]).to eq([])
    end

    it "suggests a near-miss word from the org's own mail when nothing matches" do
      create(:conversation, organization: org, subject: "Emirates booking confirmed", from_address: "noreply@emirates.com")

      get "/api/v1/orgs/#{org.key}/search", params: { q: "emirats" }, headers: headers
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["conversations"]).to eq([])
      expect(body["suggestion"]).to eq("emirates")
    end

    it "suggests a name past pg_trgm's default word-similarity threshold" do
      create(:conversation, organization: org, subject: "Meeting with Hussain", from_address: "hussain@example.com")

      # word_similarity("hssain", …) is 0.571 — under the 0.6 default, so the
      # `<%` prefilter dropped this before the ranking ever saw it.
      get "/api/v1/orgs/#{org.key}/search", params: { q: "hssain" }, headers: headers
      expect(response.parsed_body["conversations"]).to eq([])
      expect(response.parsed_body["suggestion"]).to eq("hussain")
    end

    it "corrects only the mistyped word of a multi-word query" do
      create(:conversation, organization: org, subject: "Emirates booking confirmed", from_address: "noreply@emirates.com")

      get "/api/v1/orgs/#{org.key}/search", params: { q: "booking emirats" }, headers: headers
      expect(response.parsed_body["suggestion"]).to eq("booking emirates")
    end

    it "returns no suggestion when the query already matched" do
      get "/api/v1/orgs/#{org.key}/search", params: { q: "invoice" }, headers: headers
      expect(response.parsed_body["conversations"].length).to eq(1)
      expect(response.parsed_body["suggestion"]).to be_nil
    end

    it "returns no suggestion when nothing in the corpus is close" do
      get "/api/v1/orgs/#{org.key}/search", params: { q: "zzzqqxwv" }, headers: headers
      expect(response.parsed_body["suggestion"]).to be_nil
    end

    it "never suggests a word from another org (E3)" do
      other_user = create(:user, username: "searchsuggiso")
      other_org = create(:organization, owner: other_user, domain: "searchsuggiso.com")
      create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")
      create(:conversation, organization: other_org, subject: "Emirates booking confirmed",
                            from_address: "noreply@emirates.com")

      # "emirates" exists only in the other org — suggesting it would leak that
      # a word (a vendor, a person) appears in another tenant's mail.
      get "/api/v1/orgs/#{org.key}/search", params: { q: "emirats" }, headers: headers
      expect(response.parsed_body["suggestion"]).to be_nil
    end

    # ── Structured filters (Filters popover / search operators) ──
    describe "filters" do
      let!(:from_ana) do
        conv = create(:conversation, organization: org, subject: "Budget review", from_address: "ana@example.com")
        create(:message, conversation: conv, organization: org, from_address: "Ana Lee <ana@example.com>", cc_address: "bob@example.com")
        conv
      end

      it "filters by sender across the thread's messages" do
        get "/api/v1/orgs/#{org.key}/search", params: { from: "ana" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("Budget review")
      end

      it "filters by cc" do
        get "/api/v1/orgs/#{org.key}/search", params: { cc: "bob" }, headers: headers
        expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("Budget review")
      end

      it "runs a filter-only search with no query text" do
        get "/api/v1/orgs/#{org.key}/search", params: { is: "unread" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["conversations"].length).to eq(Conversation.where(organization: org, read: false).count)
      end

      it "filters by read state" do
        from_ana.update!(read: true)
        get "/api/v1/orgs/#{org.key}/search", params: { q: "budget", is: "read" }, headers: headers
        expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("Budget review")

        get "/api/v1/orgs/#{org.key}/search", params: { q: "budget", is: "unread" }, headers: headers
        expect(response.parsed_body["conversations"]).to eq([])
      end

      it "filters by attachment presence, filename and size" do
        conv = create(:conversation, organization: org, subject: "Contract attached", from_address: "legal@example.com")
        message = create(:message, conversation: conv, organization: org)
        create(:attachment, message: message, organization: org, filename: "signed_contract.pdf", size_bytes: 8_000_000)

        get "/api/v1/orgs/#{org.key}/search", params: { is: "attachment" }, headers: headers
        expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("Contract attached")

        get "/api/v1/orgs/#{org.key}/search", params: { filename: "contract" }, headers: headers
        expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("Contract attached")

        get "/api/v1/orgs/#{org.key}/search", params: { larger: 5_000_000 }, headers: headers
        expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("Contract attached")

        get "/api/v1/orgs/#{org.key}/search", params: { smaller: 1_000_000 }, headers: headers
        expect(response.parsed_body["conversations"]).to eq([])
      end

      it "filters by file type on mime type or extension" do
        conv = create(:conversation, organization: org, subject: "Deck attached", from_address: "design@example.com")
        message = create(:message, conversation: conv, organization: org)
        create(:attachment, message: message, organization: org, filename: "deck.pptx", content_type: "application/vnd.openxmlformats-officedocument.presentationml.presentation")

        get "/api/v1/orgs/#{org.key}/search", params: { type: "pptx" }, headers: headers
        expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("Deck attached")

        get "/api/v1/orgs/#{org.key}/search", params: { type: "pdf" }, headers: headers
        expect(response.parsed_body["conversations"]).to eq([])
      end

      it "filters by date range" do
        from_ana.update!(updated_at: Time.zone.parse("2026-01-15 10:00"))

        get "/api/v1/orgs/#{org.key}/search", params: { q: "budget", after: "2026-01-14" }, headers: headers
        expect(response.parsed_body["conversations"].length).to eq(1)

        get "/api/v1/orgs/#{org.key}/search", params: { q: "budget", before: "2026-01-14" }, headers: headers
        expect(response.parsed_body["conversations"]).to eq([])
      end

      it "filters by priority tag" do
        tag = create(:tag, organization: org, name: Tag::TAG_URGENT)
        from_ana.tags << tag

        get "/api/v1/orgs/#{org.key}/search", params: { is: "urgent" }, headers: headers
        expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("Budget review")
      end

      it "never crosses orgs through a filter (E3)" do
        other_owner = create(:user, username: "otherfilter")
        other_org = create(:organization, owner: other_owner, domain: "other.com")
        other_conv = create(:conversation, organization: other_org, subject: "Budget review", from_address: "ana@example.com")
        create(:message, conversation: other_conv, organization: other_org, from_address: "ana@example.com")

        get "/api/v1/orgs/#{org.key}/search", params: { from: "ana" }, headers: headers
        keys = response.parsed_body["conversations"].map { |c| c["id"] }
        expect(keys).to contain_exactly(from_ana.key)
      end

      it "ignores an unknown is: flag rather than erroring" do
        get "/api/v1/orgs/#{org.key}/search", params: { q: "budget", is: "sideways" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["conversations"].map { |c| c["subject"] }).to contain_exactly("Budget review")
      end
    end

    it "rejects empty query" do
      get "/api/v1/orgs/#{org.key}/search", params: { q: "" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "enforces tenant isolation (E3)" do
      other_user = create(:user, username: "searchiso")
      other_org = create(:organization, owner: other_user, domain: "searchiso.com")
      create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")

      get "/api/v1/orgs/#{other_org.key}/search", params: { q: "invoice" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
