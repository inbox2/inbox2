require "rails_helper"

# docs/plans/mail-import.md — starting, listing, resuming and cancelling a
# domain's mail import. The importer itself is in spec/services/mail_importer_spec.rb.
RSpec.describe "Mail imports", type: :request do
  include ActiveJob::TestHelper

  let(:transport) { FakeImportTransport.new }
  let(:owner_user) { create(:user) }
  let(:org) { create(:organization, owner: owner_user, domain: "lalaaji.test") }
  let(:domain) { org.default_domain }
  let!(:admin) { create(:membership, user: owner_user, organization: org, role: "owner") }
  let(:ana_user) { create(:user) }
  let!(:ana) { create(:membership, user: ana_user, organization: org, role: "member") }
  let(:path) { "/api/v1/orgs/#{org.key}/mail-imports" }

  around do |example|
    keys = %w[DISK_IMPORT_GOOGLE_CLIENT_ID DISK_IMPORT_GOOGLE_CLIENT_SECRET DISK_IMPORT_GOOGLE_ORGS
              DISK_IMPORT_GOOGLE_SERVICE_ACCOUNT]
    saved = keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    ENV.update("DISK_IMPORT_GOOGLE_CLIENT_ID" => "g", "DISK_IMPORT_GOOGLE_CLIENT_SECRET" => "s", "DISK_IMPORT_GOOGLE_ORGS" => "*",
               "DISK_IMPORT_GOOGLE_SERVICE_ACCOUNT" => { client_email: "sa@x", private_key: OpenSSL::PKey::RSA.new(2048).to_pem }.to_json)
    example.run
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  before do
    Disk::Importer.transport = transport
    create(:mailbox, membership: ana, domain: domain, local_part: "ana")
    transport.on(:post, "oauth2.googleapis.com/token", { body: { access_token: "t", expires_in: 3600 } })
    transport.on(:get, %r{admin/directory/v1/users}, { body: { users: [
      { primaryEmail: "Ana@lalaaji.test" }, { primaryEmail: "cal@lalaaji.test" }, { primaryEmail: "x@other.test" }
    ] } })
  end
  after { Disk::Importer.transport = nil }

  def connect!
    Disk::ImportConnection.create!(organization: org, membership: admin, provider: "google",
                                   reach: Disk::ImportConnection::REACH_ORG, account_email: "boss@lalaaji.test")
  end

  it "queues one import per source user with a mailbox on the domain and lists the rest" do
    connect!

    post path, params: { provider: "google", domain_id: domain.key }, headers: auth_headers(owner_user), as: :json

    expect(response).to have_http_status(:accepted)
    body = response.parsed_body
    expect(body["imports"].map { |i| [i["source_email"], i["state"], i.dig("owner", "id")] })
      .to eq([["ana@lalaaji.test", "queued", ana.key]])
    expect(body["unmatched"]).to eq(["cal@lalaaji.test"])
    expect(MailImportJob).to have_been_enqueued.once

    get path, headers: auth_headers(owner_user)
    expect(response.parsed_body["imports"].size).to eq(1)
    expect(response.parsed_body["sources"]).to include({ "provider" => "google", "offered" => true, "connected" => true })
  end

  it "asks again to re-run a finished import (the catch-up after the MX flip) without a second row" do
    connect!
    post path, params: { provider: "google", domain_id: domain.key }, headers: auth_headers(owner_user), as: :json
    MailImport.last.update!(state: MailImport::STATE_DONE, cursor: '{"history":"9","done":true}')

    post path, params: { provider: "google", domain_id: domain.key }, headers: auth_headers(owner_user), as: :json

    expect(MailImport.count).to eq(1)
    expect(MailImport.last).to have_attributes(state: "queued", cursor: '{"history":"9","done":true}')
  end

  it "refuses until Google is connected for the whole organization" do
    post path, params: { provider: "google", domain_id: domain.key }, headers: auth_headers(owner_user), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("errors", 0, "message")).to include("Connect Google")
  end

  it "resumes and cancels" do
    connect!
    post path, params: { provider: "google", domain_id: domain.key }, headers: auth_headers(owner_user), as: :json
    import = MailImport.last

    delete "#{path}/#{import.key}", headers: auth_headers(owner_user)
    expect(import.reload).to be_cancelled

    post "#{path}/#{import.key}/resume", headers: auth_headers(owner_user)
    expect(import.reload).to be_queued
  end

  it "refuses to resume a Takeout import, which only its file can resume" do
    import = MailImport.create!(organization: org, membership: ana, owner: ana, domain: domain, provider: MailImport::TAKEOUT,
                                source_email: "ana@lalaaji.test", state: MailImport::STATE_PAUSED)

    post "#{path}/#{import.key}/resume", headers: auth_headers(owner_user)

    expect(response).to have_http_status(:unprocessable_content)
    expect(import.reload).to be_paused
    expect(enqueued_jobs).to be_empty
  end

  it "is for owners and admins only" do
    get path, headers: auth_headers(ana_user)
    expect(response).to have_http_status(:forbidden)
  end

  it "does not reach another organization's imports" do
    other = create(:organization)
    create(:membership, user: owner_user, organization: other, role: "owner")
    connect!
    post path, params: { provider: "google", domain_id: domain.key }, headers: auth_headers(owner_user), as: :json

    post "/api/v1/orgs/#{other.key}/mail-imports/#{MailImport.last.key}/resume", headers: auth_headers(owner_user)
    expect(response).to have_http_status(:not_found)
  end
end
