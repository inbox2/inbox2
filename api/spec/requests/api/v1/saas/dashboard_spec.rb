require "rails_helper"

RSpec.describe "Api::V1::Saas::Dashboard", :saas, type: :request do
  let(:credential) { create(:admin_credential) }
  let(:headers) { saas_headers(credential) }

  def json = JSON.parse(response.body)

  it "returns account-wide metrics" do
    create(:organization)
    suspended = create(:organization)
    suspended.suspend!("abuse")

    get "/api/v1/saas/dashboard", headers: headers

    expect(response).to have_http_status(:ok)
    metrics = json["metrics"]
    expect(metrics["organizations"]["total"]).to be >= 2
    expect(metrics["organizations"]["suspended"]).to be >= 1
    expect(metrics).to include("users", "mailboxes", "plans", "mail")
    expect(metrics["plans"]).to include("free", "paid")
  end
end
