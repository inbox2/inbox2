require "rails_helper"

# 48.18: in production /api/v1/saas exists only on the role that sets the flag.
RSpec.describe "Operator plane routing", type: :request do
  let(:production) { ActiveSupport::EnvironmentInquirer.new("production") }

  around do |example|
    was = ENV.delete("SAAS_OPERATOR_PLANE")
    example.run
  ensure
    ENV["SAAS_OPERATOR_PLANE"] = was
  end

  before { allow(Rails).to receive(:env).and_return(production) }

  it "has no such route on a public role, whatever the request claims" do
    expect {
      get "/api/v1/saas/dashboard", headers: {
        "ssl-client-verify" => "SUCCESS", "ssl-client-fingerprint" => "abc",
        "Host" => "operator.inbox2.internal:4000", "X-Forwarded-Port" => "4000"
      }
      raise ActionController::RoutingError, "404" if response.status == 404
    }.to raise_error(ActionController::RoutingError)
  end

  it "reaches the controller on the operator role, which still wants a credential" do
    ENV["SAAS_OPERATOR_PLANE"] = "1"
    get "/api/v1/saas/dashboard"
    expect(response).to have_http_status(:unauthorized)
  end
end
