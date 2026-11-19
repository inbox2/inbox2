require "rails_helper"

# The Pushleft App admin API (docs/SaaS.md): the signed request, then every
# resource and action.
RSpec.describe "Pushleft admin", type: :request do
  prefix = "/_pushleft/admin"
  audience = "org_1/inbox2/production"
  signing_key = OpenSSL::PKey::EC.generate("prime256v1")

  around do |example|
    saved = ENV.to_h.slice("PUSHLEFT_ADMIN_JWKS", "PUSHLEFT_ADMIN_AUDIENCE")
    ENV["PUSHLEFT_ADMIN_JWKS"] = { keys: [ JWT::JWK.new(signing_key, kid: "k1").export ] }.to_json
    ENV["PUSHLEFT_ADMIN_AUDIENCE"] = audience
    example.run
  ensure
    %w[PUSHLEFT_ADMIN_JWKS PUSHLEFT_ADMIN_AUDIENCE].each { |name| ENV[name] = saved[name] }
  end

  define_method(:claims) do |method, path, body = "", **overrides|
    now = Time.now.to_i
    { iss: "https://api.pushleft.dev", aud: audience, sub: "ops@example.com", role: "owner",
      iat: now, exp: now + 60, jti: SecureRandom.uuid,
      method: method, path: path, body: Digest::SHA256.hexdigest(body) }.merge(overrides)
  end

  define_method(:sign) do |method, path, body = "", key: signing_key, kid: "k1", **overrides|
    JWT.encode(claims(method, path, body, **overrides), key, "ES256", { kid: kid }.compact)
  end

  # A signed call (or one carrying `token`); the parsed answer.
  define_method(:call) do |method, path, body = nil, token: nil|
    raw = body.nil? || body.is_a?(String) ? body.to_s : body.to_json
    headers = { "Authorization" => "Bearer #{token || sign(method, "#{prefix}#{path}", raw)}" }
    headers["Content-Type"] = "application/json" unless body.nil?
    public_send(method.downcase, "#{prefix}#{path}", params: (raw unless body.nil?), headers: headers)
    response.parsed_body
  end

  def error_code = response.parsed_body.dig("error", "code")
  def last_audit = SaasAuditLog.order(:id).last

  # ── The signed request ───────────────────────────────────────────────────────

  describe "the token" do
    it "accepts a request signed for it" do
      call("GET", "/schema")
      expect(response).to have_http_status(:ok)
    end

    it "refuses a request without a token, in the error shape" do
      get "#{prefix}/schema"
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq("error" => { "code" => "unauthorized",
                                                      "message" => "A valid Pushleft admin token is required" })
    end

    it "does not take a signed-in user's session as an admin token" do
      get "#{prefix}/users", headers: auth_headers(create(:user))
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses alg none" do
      call("GET", "/schema", token: JWT.encode(claims("GET", "#{prefix}/schema"), nil, "none", { kid: "k1" }))
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses a symmetric algorithm keyed with the public key" do
      forged = JWT.encode(claims("GET", "#{prefix}/schema"), signing_key.public_to_pem, "HS256", { kid: "k1" })
      call("GET", "/schema", token: forged)
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses another ECDSA algorithm" do
      other = OpenSSL::PKey::EC.generate("secp384r1")
      ENV["PUSHLEFT_ADMIN_JWKS"] = { keys: [ JWT::JWK.new(other, kid: "k1").export ] }.to_json
      call("GET", "/schema", token: JWT.encode(claims("GET", "#{prefix}/schema"), other, "ES384", { kid: "k1" }))
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses an unknown kid and a missing kid" do
      call("GET", "/schema", token: sign("GET", "#{prefix}/schema", kid: "k2"))
      expect(response).to have_http_status(:unauthorized)

      call("GET", "/schema", token: sign("GET", "#{prefix}/schema", kid: nil))
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses a signature by another key" do
      call("GET", "/schema", token: sign("GET", "#{prefix}/schema", key: OpenSSL::PKey::EC.generate("prime256v1")))
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses another audience and another issuer" do
      call("GET", "/schema", token: sign("GET", "#{prefix}/schema", aud: "org_1/inbox2/preview"))
      expect(response).to have_http_status(:unauthorized)

      call("GET", "/schema", token: sign("GET", "#{prefix}/schema", aud: [ audience, "org_2/other/production" ]))
      expect(response).to have_http_status(:unauthorized)

      call("GET", "/schema", token: sign("GET", "#{prefix}/schema", iss: "https://api.pushleft.example"))
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses an expired token, with 30 seconds of clock difference allowed" do
      call("GET", "/schema", token: sign("GET", "#{prefix}/schema", exp: Time.now.to_i - 31))
      expect(response).to have_http_status(:unauthorized)

      call("GET", "/schema", token: sign("GET", "#{prefix}/schema", exp: Time.now.to_i - 20))
      expect(response).to have_http_status(:ok)
    end

    it "refuses a token issued in the future, with 30 seconds of clock difference allowed" do
      call("GET", "/schema", token: sign("GET", "#{prefix}/schema", iat: Time.now.to_i + 90, exp: Time.now.to_i + 150))
      expect(response).to have_http_status(:unauthorized)

      call("GET", "/schema", token: sign("GET", "#{prefix}/schema", iat: Time.now.to_i + 20))
      expect(response).to have_http_status(:ok)
    end

    it "refuses a token without exp, iat, iss or sub" do
      %i[exp iat iss sub].each do |claim|
        token = JWT.encode(claims("GET", "#{prefix}/schema").except(claim), signing_key, "ES256", { kid: "k1" })
        call("GET", "/schema", token: token)
        expect(response).to have_http_status(:unauthorized), "without #{claim}"
      end
    end

    it "refuses a token for another method" do
      org = create(:organization)
      path = "/organizations/#{org.key}/actions/suspend"
      call("POST", path, token: sign("GET", "#{prefix}#{path}"))
      expect(response).to have_http_status(:unauthorized)
      expect(org.reload).not_to be_suspended
    end

    it "refuses a token for another path or another query string" do
      call("GET", "/users", token: sign("GET", "#{prefix}/schema"))
      expect(response).to have_http_status(:unauthorized)

      call("GET", "/users?limit=200", token: sign("GET", "#{prefix}/users"))
      expect(response).to have_http_status(:unauthorized)

      call("GET", "/users", token: sign("GET", "#{prefix}/users?limit=200"))
      expect(response).to have_http_status(:unauthorized)

      # The comparison is with the target as sent, not a decoded form of it.
      call("GET", "/organizations?view=susp%65nded", token: sign("GET", "#{prefix}/organizations?view=suspended"))
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses a changed body" do
      org = create(:organization, name: "Signed for")
      signed_for = { values: { name: "Signed" } }.to_json

      call("PATCH", "/organizations/#{org.key}", { values: { name: "Swapped" } },
           token: sign("PATCH", "#{prefix}/organizations/#{org.key}", signed_for))
      expect(response).to have_http_status(:unauthorized)
      expect(org.reload.name).to eq("Signed for")
    end

    it "answers 404 on every path when a variable is missing, even to a valid token" do
      %w[PUSHLEFT_ADMIN_JWKS PUSHLEFT_ADMIN_AUDIENCE].each do |missing|
        token = sign("GET", "#{prefix}/schema")
        saved = ENV[missing]
        ENV[missing] = nil

        call("GET", "/schema", token: token)
        expect(response).to have_http_status(:not_found), "with #{missing} unset"
        expect(response.body).to be_empty
        get "#{prefix}/users"
        expect(response).to have_http_status(:not_found)
        post "#{prefix}/anything/at/all"
        expect(response).to have_http_status(:not_found)
      ensure
        ENV[missing] = saved
      end
    end

    it "refuses instead of failing open on a malformed key set" do
      token = sign("GET", "#{prefix}/schema")
      [ "{not json", "{}", { keys: [ { kty: "EC", crv: "P-256", kid: "k1" } ] }.to_json ].each do |jwks|
        ENV["PUSHLEFT_ADMIN_JWKS"] = jwks
        call("GET", "/schema", token: token)
        expect(response).to have_http_status(:unauthorized), jwks
      end
    end

    it "puts unknown paths under the prefix behind the token too" do
      [ "", "/", "/nothing/here/at/all", "/users/x/actions/disable/more" ].each do |path|
        get "#{prefix}#{path}"
        expect(response).to have_http_status(:unauthorized), path.inspect

        call("GET", path)
        expect(response).to have_http_status(:not_found), path.inspect
        expect(error_code).to eq("not_found")
      end

      # No resource is created or deleted here, with a token or without.
      call("POST", "/organizations", { values: { name: "New" } })
      expect(response).to have_http_status(:not_found)
      call("DELETE", "/organizations/#{create(:organization).key}")
      expect(response).to have_http_status(:not_found)
      delete "#{prefix}/organizations/x"
      expect(response).to have_http_status(:unauthorized)
    end

    it "matches the prefix on a path segment" do
      # A valid token for the look-alike path gets what any unknown path gets:
      # the admin API is not there.
      path = "/_pushleft/adminx/schema"
      get path, headers: { "Authorization" => "Bearer #{sign('GET', path)}" }
      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include("protocol")

      path = "/_pushleft/administrator"
      get path, headers: { "Authorization" => "Bearer #{sign('GET', path)}" }
      expect(response).to have_http_status(:not_found)
    end

    it "answers on any host, with no redirect, cookie or session" do
      host! "inbox2--205eb939.apps.pushleft.dev"
      call("GET", "/schema")
      expect(response).to have_http_status(:ok)
      expect(response.headers["Set-Cookie"]).to be_nil
      expect(response.headers["Location"]).to be_nil
    end

    it "is outside the app's rate limits, on the segment and not on a look-alike" do
      safelisted = ->(path) { Rack::Attack.safelists["pushleft-admin"].matched_by?(Rack::Attack::Request.new(Rack::MockRequest.env_for(path))) }
      expect(safelisted.call("#{prefix}/users?limit=5")).to be_truthy
      expect(safelisted.call(prefix)).to be_truthy
      expect(safelisted.call("/_pushleft/adminx/api/v1/auth/login")).to be_falsey
      expect(safelisted.call("/api/v1/auth/login")).to be_falsey
    end

    it "answers malformed JSON with 400 with a token and 401 without" do
      path = "/organizations/#{create(:organization).key}"
      patch "#{prefix}#{path}", params: "{oops", headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unauthorized)

      call("PATCH", path, "{oops")
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("bad_request")
    end

    it "answers a query string that cannot be parsed with 400 with a token and 401 without" do
      [ "/users?filter=x&filter[role]=owner", "/users?q=%FF", "/schema?a=1&a[b]=2" ].each do |path|
        get "#{prefix}#{path}"
        expect(response).to have_http_status(:unauthorized), path

        call("GET", path)
        expect(response).to have_http_status(:bad_request), path
        expect(error_code).to eq("bad_request"), path
      end
    end

    it "logs a write with its actor" do
      org = create(:organization)
      lines = []
      allow(Rails.logger).to receive(:info) { |*args| lines << args.first.to_s }
      body = { input: { reason: "Unpaid" } }
      path = "/organizations/#{org.key}/actions/suspend"

      call("POST", path, body, token: sign("POST", "#{prefix}#{path}", body.to_json,
                                           sub: "ana@ops.example", role: "admin", jti: "req_123"))
      expect(response).to have_http_status(:ok)

      line = lines.grep(/\[PushleftAdmin\] write/).sole
      expect(line).to include('sub="ana@ops.example"', 'role="admin"', 'jti="req_123"',
                              "POST #{prefix}#{path} status=200")
      expect(last_audit).to have_attributes(action: SaasAuditLog::ACTION_ORG_SUSPEND, admin_credential_id: nil,
                                            target_key: org.key)
      expect(last_audit.metadata).to include("operator" => "ana@ops.example", "request_id" => "req_123",
                                             "reason" => "Unpaid")
    end
  end

  # ── Schema and overview ──────────────────────────────────────────────────────

  describe "GET /schema" do
    it "describes the resources in protocol 1, with nothing of the app's internals" do
      body = call("GET", "/schema")
      expect(body).to include("protocol" => 1, "title" => "inbox2", "overview" => true)
      expect(body["resources"].map { |r| r["name"] })
        .to eq(%w[users organizations memberships domains plans waitlist])

      users, orgs = body["resources"].first(2)
      expect(users).to include("kind" => "user", "can" => %w[list show], "search" => true)
      expect(orgs).to include("kind" => "tenant", "can" => %w[list show update])
      expect(orgs["children"]).to eq([ { "resource" => "memberships", "field" => "organization" },
                                      { "resource" => "domains", "field" => "organization" } ])
      expect(users["fields"].find { |f| f["is"] == "last_seen" })
        .to include("name" => "last_sign_in_at", "type" => "datetime", "sort" => true)
      expect(orgs["fields"].select { |f| f["update"] }.map { |f| f["name"] })
        .to eq(%w[name mailbox_limit disk_quota_gb])

      allowed = {
        resource: %w[name label singular kind can search views children fields actions],
        field: %w[name type label help required default list filter sort create update is group
                  min max max_length unit options resource],
        action: %w[name label on input confirm danger]
      }
      body["resources"].each do |res|
        expect(res.keys - allowed[:resource]).to be_empty, res["name"]
        res["fields"].each { |field| expect(field.keys - allowed[:field]).to be_empty, "#{res['name']}.#{field['name']}" }
        res["actions"].each do |action|
          expect(action.keys - allowed[:action]).to be_empty, "#{res['name']}.#{action['name']}"
          (action["input"] || []).each { |field| expect(field.keys - allowed[:field]).to be_empty }
        end
        # Every ref names a resource of this schema.
        refs = (res["fields"] + res["actions"].flat_map { |a| a["input"] || [] }).select { |f| f["type"] == "ref" }
        expect(refs.map { |f| f["resource"] } - body["resources"].map { |r| r["name"] }).to be_empty
      end

      danger = body["resources"].flat_map { |r| r["actions"].select { |a| a["danger"] }.map { |a| "#{r['name']}.#{a['name']}" } }
      expect(danger).to eq(%w[users.offboard organizations.wipe memberships.remove])
      expect(response.body).not_to include("—")
    end
  end

  describe "GET /overview" do
    it "gives the operator dashboard's counts as tiles" do
      create(:organization)
      create(:organization, suspended_at: Time.current)
      create(:waitlist_signup)

      tiles = call("GET", "/overview")["tiles"].index_by { |tile| tile["label"] }
      expect(response).to have_http_status(:ok)
      expect(tiles["Organizations"]).to eq("label" => "Organizations", "value" => 2, "resource" => "organizations")
      expect(tiles["Suspended organizations"]).to include("value" => 1, "view" => "suspended")
      expect(tiles["Waiting for an invite"]).to include("value" => 1, "resource" => "waitlist", "view" => "pending")
      expect(tiles["Disk used"]).to include("unit" => "bytes")
    end
  end

  # Prosopite (rails_helper) raises on a query repeated per row.
  it "renders a page of every list without a query per row" do
    4.times do
      org = create(:organization)
      member = create(:membership, organization: org, user: org.owner, role: "owner")
      create(:mailbox, membership: member, domain: org.default_domain)
      create(:membership, organization: org)
      create(:waitlist_signup, status: WaitlistSignup::STATUS_REGISTERED, user: org.owner)
      create(:plan)
    end

    %w[users organizations memberships domains plans waitlist].each do |resource|
      body = call("GET", "/#{resource}")
      expect(response).to have_http_status(:ok), resource
      expect(body["items"].size).to be >= 3
    end
  end

  # ── Users ────────────────────────────────────────────────────────────────────

  describe "users" do
    it "lists people by last sign-in, newest first, with string ids, typed values and their actions" do
      org = create(:organization, name: "Acme")
      early = create(:user, display_name: "Early", last_sign_in_at: 3.days.ago)
      late = create(:user, display_name: "Late", last_sign_in_at: 1.hour.ago, avatar_url: "https://img.example/late.png")
      never = create(:user, display_name: "", username: "never_in", avatar_url: "avatars/usr_1/a.png")
      create(:membership, user: late, organization: org, role: "admin")
      create(:membership, user: late, organization: create(:organization, name: "Beta"), role: "owner")
      create(:membership, user: early, organization: org, status: Membership::STATUS_DISABLED)
      Organization.personal_for(late)

      body = call("GET", "/users")
      expect(response).to have_http_status(:ok)
      people = [ late, early, never, org.owner ].map(&:key)
      listed = body["items"].select { |item| people.include?(item["id"]) }
      expect(listed.map { |item| item["id"] }.first(3)).to eq([ late.key, early.key, never.key ])
      expect(body["total"]).to eq(User.count)
      expect(body["next"]).to be_nil

      item = listed.first
      expect(item["values"]).to include(
        "name" => "Late", "email" => late.billing_email, "username" => late.username,
        "avatar" => "https://img.example/late.png", "organizations" => %w[Acme Beta], "role" => "owner",
        "status" => "active", "last_sign_in_at" => late.last_sign_in_at.utc.iso8601,
        "created_at" => late.created_at.utc.iso8601
      )
      expect(item["actions"]).to eq(%w[reset_password disable offboard])
      expect(listed.second["values"]).to include("status" => "disabled", "role" => "member")
      expect(listed.second["actions"]).to eq(%w[reset_password enable offboard])
      # A stored avatar is behind a signed link that changes on every call: left out.
      expect(listed.third["values"]).to include("name" => "never_in", "avatar" => nil, "status" => nil,
                                                "role" => nil, "organizations" => [], "last_sign_in_at" => nil)
      expect(listed.third["actions"]).to eq(%w[reset_password])
      expect(response.body).not_to include(%("id":#{late.id}))
    end

    it "sets the last sign-in when a session is created" do
      user = create(:user, password: "password123")
      expect(user.last_sign_in_at).to be_nil

      post "/api/v1/auth/login", params: { username: user.username, password: "password123" }, as: :json
      expect(response).to have_http_status(:ok)
      expect(user.reload.last_sign_in_at).to be_within(5.seconds).of(Time.current)
    end

    it "shows one person, and answers 404 for unknown and malformed ids" do
      user = create(:user)
      expect(call("GET", "/users/#{user.key}")).to include("id" => user.key)

      [ "usr_nobody", user.id.to_s, create(:organization).key, "usr_%00" ].each do |id|
        call("GET", "/users/#{id}")
        expect(response).to have_http_status(:not_found), id
        expect(error_code).to eq("not_found")
      end
      call("GET", "/nothing/#{user.key}")
      expect(response).to have_http_status(:not_found)
    end

    it "searches, treating LIKE wildcards as text" do
      alice = create(:user, username: "alice_op", billing_email: "alice@x.test")
      create(:user, username: "bob_op", billing_email: "bob@x.test")

      expect(call("GET", "/users?q=alice@x")["items"].map { |i| i["id"] }).to eq([ alice.key ])
      expect(call("GET", "/users?q=%25")["items"]).to be_empty
    end

    it "takes views, date filters, sorts and pages" do
      old = create(:user, username: "a_old", last_sign_in_at: 3.days.ago)
      recent = create(:user, username: "b_recent", last_sign_in_at: 1.hour.ago)
      create(:user, username: "c_never")

      expect(call("GET", "/users?view=signed_in_24h")["items"].map { |i| i["id"] }).to eq([ recent.key ])

      since = CGI.escape(2.days.ago.utc.iso8601)
      expect(call("GET", "/users?filter[last_sign_in_at][gte]=#{since}")["items"].map { |i| i["id"] }).to eq([ recent.key ])
      expect(call("GET", "/users?filter[last_sign_in_at][lte]=#{since}")["items"].map { |i| i["id"] }).to eq([ old.key ])

      expect(call("GET", "/users?sort=username")["items"].map { |i| i["values"]["username"] })
        .to eq(%w[a_old b_recent c_never])

      first = call("GET", "/users?sort=username&limit=2")
      expect(first["items"].size).to eq(2)
      expect(first["total"]).to eq(3)
      rest = call("GET", "/users?sort=username&limit=2&after=#{first['next']}")
      expect(rest["items"].map { |i| i["values"]["username"] }).to eq(%w[c_never])
      expect(rest["next"]).to be_nil
    end

    it "refuses list parameters outside the schema with 400" do
      create(:user)
      [ "/users?view=nope", "/users?sort=avatar", "/users?sort=password_digest", "/users?filter[username]=x",
        "/users?filter[password_digest]=x", "/users?filter[last_sign_in_at]=yesterday",
        "/users?filter[last_sign_in_at][gt]=2026-01-01T00:00:00Z", "/users?limit=0", "/users?limit=many",
        "/users?after=zzz", "/users?page=2", "/users?q[]=a", "/memberships?filter[role]=root",
        "/memberships?filter[organization]=1", "/memberships?filter[role][gte]=owner",
        "/organizations?filter[status]=gone", "/plans?filter[tier]=free" ].each do |path|
        call("GET", path)
        expect(response).to have_http_status(:bad_request), path
        expect(error_code).to eq("bad_request"), path
      end
    end

    it "reset_password mails a reset link and does not return it" do
      user = create(:user, billing_email: "reset@me.test")

      body = nil
      expect { body = call("POST", "/users/#{user.key}/actions/reset_password", { input: {} }) }
        .to have_enqueued_job(MessyTriggerJob)
      expect(response).to have_http_status(:ok)
      expect(body).to include("message" => "A reset link was mailed to reset@me.test")
      expect(body).not_to have_key("reveal")
      expect(body["item"]["id"]).to eq(user.key)
      expect(user.reload.reset_token).to be_present
      expect(last_audit).to have_attributes(action: SaasAuditLog::ACTION_USER_RESET_PASSWORD, target_key: user.key)
      expect(last_audit.metadata).to include("operator" => "ops@example.com")
    end

    it "reset_password refuses a person without an email address" do
      user = create(:user, billing_email: nil)

      expect { call("POST", "/users/#{user.key}/actions/reset_password") }.not_to have_enqueued_job(MessyTriggerJob)
      expect(response).to have_http_status(:conflict)
      expect(error_code).to eq("conflict")
      expect(SaasAuditLog.count).to eq(0)
    end

    it "disable disables every membership and signs the person out; enable turns them back on" do
      user = create(:user)
      create(:membership, user: user)
      create(:membership, user: user)
      create(:session, user: user)

      body = call("POST", "/users/#{user.key}/actions/disable")
      expect(response).to have_http_status(:ok)
      expect(user.memberships.pluck(:status).uniq).to eq([ Membership::STATUS_DISABLED ])
      expect(user.sessions.count).to eq(0)
      expect(body["item"]["values"]["status"]).to eq("disabled")
      expect(body["item"]["actions"]).to include("enable")
      expect(last_audit.action).to eq(SaasAuditLog::ACTION_USER_DISABLE)

      body = call("POST", "/users/#{user.key}/actions/enable")
      expect(response).to have_http_status(:ok)
      expect(user.memberships.pluck(:status).uniq).to eq([ Membership::STATUS_ACTIVE ])
      expect(body["item"]["values"]["status"]).to eq("active")
      expect(last_audit.action).to eq(SaasAuditLog::ACTION_USER_ENABLE)
    end

    it "disable and enable refuse when there is nothing to change" do
      user = create(:user)
      create(:membership, user: user)

      call("POST", "/users/#{user.key}/actions/enable")
      expect(response).to have_http_status(:conflict)

      call("POST", "/users/#{user.key}/actions/disable")
      call("POST", "/users/#{user.key}/actions/disable")
      expect(response).to have_http_status(:conflict)
      expect(SaasAuditLog.count).to eq(1)
    end

    it "offboard removes the person from every organization" do
      user = create(:user)
      create(:membership, user: user)
      create(:membership, user: user)
      create(:session, user: user)

      body = call("POST", "/users/#{user.key}/actions/offboard",
                  { input: { data_handling: "archive", alias_handling: "bounce" } })
      expect(response).to have_http_status(:ok)
      expect(Membership.where(user: user).count).to eq(0)
      expect(user.sessions.count).to eq(0)
      expect(body["item"]["values"]).to include("organizations" => [], "status" => nil)
      expect(last_audit).to have_attributes(action: SaasAuditLog::ACTION_USER_OFFBOARD, target_key: user.key)
    end

    it "offboard reroutes the old address to a colleague, and wipes mail only when asked" do
      org = create(:organization)
      user = create(:user)
      leaving = create(:membership, user: user, organization: org)
      colleague = create(:membership, organization: org)
      mailbox = create(:mailbox, membership: leaving, domain: org.default_domain, local_part: "leaving")

      call("POST", "/users/#{user.key}/actions/offboard",
           { input: { data_handling: "wipe", alias_handling: "reroute", reroute_target: colleague.key } })
      expect(response).to have_http_status(:ok)
      expect(org.mailbox_aliases.find_by(local_part: mailbox.local_part))
        .to have_attributes(mode: MailboxAlias::MODE_REROUTE, target_membership_id: colleague.id)
    end

    it "offboard refuses inputs that are missing, unknown or not valid, and removes nothing" do
      org = create(:organization)
      user = create(:user)
      leaving = create(:membership, user: user, organization: org)
      create(:mailbox, membership: leaving, domain: org.default_domain)
      outsider = create(:membership)
      path = "/users/#{user.key}/actions/offboard"

      {
        {} => { "data_handling" => "is required", "alias_handling" => "is required" },
        { data_handling: "shred", alias_handling: "bounce" } => { "data_handling" => "is not one of the options" },
        { data_handling: "archive", alias_handling: "bounce", purge: true } => { "purge" => "cannot be set here" },
        { data_handling: "archive", alias_handling: "reroute" } => { "reroute_target" => "is required" },
        { data_handling: "archive", alias_handling: "bounce", reroute_target: outsider.key } =>
          { "reroute_target" => "only with Deliver to a colleague" },
        { data_handling: "archive", alias_handling: "reroute", reroute_target: "7" } =>
          { "reroute_target" => "does not exist" },
        { data_handling: "archive", alias_handling: "reroute", reroute_target: outsider.key } =>
          { "reroute_target" => "must be an active member of the same organization" },
        { data_handling: "archive", alias_handling: "reroute", reroute_target: leaving.key } =>
          { "reroute_target" => "must be an active member of the same organization" }
      }.each do |input, fields|
        body = call("POST", path, { input: input })
        expect(response).to have_http_status(:unprocessable_content), input.to_s
        expect(body["error"]).to include("code" => "invalid", "fields" => fields)
      end

      [ { input: [] }, { inputs: {} }, { input: {}, extra: 1 }, [] ].each do |malformed|
        call("POST", path, malformed)
        expect(response).to have_http_status(:bad_request), malformed.to_s
      end
      expect(leaving.reload).to be_persisted
      expect(SaasAuditLog.count).to eq(0)
    end

    it "answers 404 for an unknown action" do
      call("POST", "/users/#{create(:user).key}/actions/delete")
      expect(response).to have_http_status(:not_found)
      call("POST", "/users/#{create(:user).key}/actions/suspend")
      expect(response).to have_http_status(:not_found)
    end
  end

  # ── Organizations ────────────────────────────────────────────────────────────

  describe "organizations" do
    it "lists team organizations with plan, limits and member count, and never a personal workspace" do
      plan = create(:plan, name: "Enterprise")
      acme = create(:organization, name: "Acme", domain: "acme.test", plan: plan, mailbox_limit: 5,
                                   disk_quota_override_gb: 50, disk_bytes_used: 2048)
      create(:organization, name: "Beta", suspended_at: Time.current, suspended_reason: "Unpaid")
      create(:organization, name: "Gamma")
      member = create(:membership, organization: acme)
      create(:membership, organization: acme)
      create(:mailbox, membership: member, domain: acme.default_domain)
      personal = Organization.personal_for(create(:user))

      body = call("GET", "/organizations?sort=name")
      expect(response).to have_http_status(:ok)
      expect(body["items"].map { |i| i["values"]["name"] }).to eq(%w[Acme Beta Gamma])
      expect(body["total"]).to eq(3)

      item = body["items"].first
      expect(item["id"]).to eq(acme.key)
      expect(item["values"]).to include(
        "name" => "Acme", "domain" => "acme.test", "status" => "active", "suspended_reason" => nil,
        "plan" => { "id" => plan.key, "label" => "Enterprise" },
        "plan_override" => { "id" => plan.key, "label" => "Enterprise" },
        "owner" => { "id" => acme.owner.key, "label" => "Test User" },
        "member_count" => 2, "mailbox_limit" => 5, "disk_quota_gb" => 50, "mailbox_count" => 1,
        "conversation_count" => 0, "message_count" => 0, "attachment_count" => 0, "storage_bytes" => 0,
        "disk_bytes_used" => 2048, "created_at" => acme.created_at.utc.iso8601
      )
      expect(item["actions"]).to eq(%w[suspend set_plan wipe])

      suspended = body["items"].second
      expect(suspended["values"]).to include("status" => "suspended", "suspended_reason" => "Unpaid",
                                             "plan" => { "id" => Plan.free.key, "label" => Plan.free.name },
                                             "plan_override" => nil, "mailbox_limit" => nil, "disk_quota_gb" => nil)
      expect(suspended["actions"]).to eq(%w[unsuspend set_plan wipe])

      call("GET", "/organizations/#{personal.key}")
      expect(response).to have_http_status(:not_found)
    end

    it "shows one organization, searches by name and domain, and filters by status and view" do
      acme = create(:organization, name: "Acme", domain: "acme-mail.test")
      beta = create(:organization, name: "Beta", suspended_at: Time.current)

      expect(call("GET", "/organizations/#{acme.key}")).to include("id" => acme.key)
      expect(call("GET", "/organizations?q=acme-mail")["items"].map { |i| i["id"] }).to eq([ acme.key ])
      expect(call("GET", "/organizations?q=bet")["items"].map { |i| i["id"] }).to eq([ beta.key ])
      expect(call("GET", "/organizations?view=suspended")["items"].map { |i| i["id"] }).to eq([ beta.key ])
      expect(call("GET", "/organizations?filter[status]=active")["items"].map { |i| i["id"] }).to eq([ acme.key ])
      expect(call("GET", "/organizations?filter[status]=active,suspended")["total"]).to eq(2)
    end

    it "updates the name, the mailbox limit and the disk quota, each with its audit row" do
      org = create(:organization, name: "Before", mailbox_limit: 5)

      body = call("PATCH", "/organizations/#{org.key}",
                  { values: { name: "  After  ", mailbox_limit: nil, disk_quota_gb: 100 } })
      expect(response).to have_http_status(:ok)
      expect(body["item"]["values"]).to include("name" => "After", "mailbox_limit" => nil, "disk_quota_gb" => 100)
      expect(org.reload).to have_attributes(name: "After", mailbox_limit: nil, disk_quota_override_gb: 100)
      expect(SaasAuditLog.order(:id).pluck(:action)).to eq([ SaasAuditLog::ACTION_ORG_UPDATE,
                                                            SaasAuditLog::ACTION_ORG_MAILBOX_LIMIT,
                                                            SaasAuditLog::ACTION_ORG_DISK_QUOTA ])
      expect(last_audit.metadata).to include("quota_gb" => 100, "operator" => "ops@example.com")

      call("PATCH", "/organizations/#{org.key}", { values: { mailbox_limit: 0 } })
      expect(org.reload.mailbox_limit).to eq(0)
    end

    it "refuses an update with values that are not valid or fields that are not editable, and changes nothing" do
      org = create(:organization, name: "Before", mailbox_limit: 5)

      {
        { name: "" } => { "name" => "is required" },
        { name: "x" * 256 } => { "name" => "is too long (at most 255 characters)" },
        { name: 7 } => { "name" => "must be text" },
        { mailbox_limit: -1 } => { "mailbox_limit" => "must be from 0 to #{Plan::UNLIMITED}" },
        { mailbox_limit: "5" } => { "mailbox_limit" => "must be a whole number" },
        { mailbox_limit: 1.5 } => { "mailbox_limit" => "must be a whole number" },
        { disk_quota_gb: 1_000_001 } => { "disk_quota_gb" => "must be from 0 to 1000000" },
        { name: "After", slug: "taken" } => { "slug" => "cannot be set here" },
        { suspended_at: nil } => { "suspended_at" => "cannot be set here" },
        { plan: "plan_x" } => { "plan" => "cannot be set here" }
      }.each do |values, fields|
        body = call("PATCH", "/organizations/#{org.key}", { values: values })
        expect(response).to have_http_status(:unprocessable_content), values.to_s
        expect(body["error"]).to include("code" => "invalid", "fields" => fields)
      end

      expect(org.reload).to have_attributes(name: "Before", mailbox_limit: 5)
      expect(SaasAuditLog.count).to eq(0)

      call("PATCH", "/users/#{create(:user).key}", { values: { username: "x" } })
      expect(response).to have_http_status(:not_found)
    end

    it "suspend records the reason, unsuspend clears it" do
      org = create(:organization, name: "Acme")

      body = call("POST", "/organizations/#{org.key}/actions/suspend", { input: { reason: "Unpaid invoice" } })
      expect(response).to have_http_status(:ok)
      expect(body["message"]).to eq("Acme is suspended")
      expect(body["item"]["values"]).to include("status" => "suspended", "suspended_reason" => "Unpaid invoice")
      expect(org.reload).to be_suspended
      expect(last_audit.metadata).to include("reason" => "Unpaid invoice")

      body = call("POST", "/organizations/#{org.key}/actions/unsuspend")
      expect(response).to have_http_status(:ok)
      expect(body["item"]["values"]).to include("status" => "active", "suspended_reason" => nil)
      expect(org.reload).not_to be_suspended
      expect(last_audit.action).to eq(SaasAuditLog::ACTION_ORG_UNSUSPEND)
    end

    it "suspend refuses a reason that is too long, an unknown input and a second suspension" do
      org = create(:organization)
      path = "/organizations/#{org.key}/actions/suspend"

      body = call("POST", path, { input: { reason: "x" * 501 } })
      expect(response).to have_http_status(:unprocessable_content)
      expect(body["error"]["fields"]).to eq("reason" => "is too long (at most 500 characters)")

      call("POST", path, { input: { reason: "ok", until: "2027-01-01" } })
      expect(response).to have_http_status(:unprocessable_content)
      expect(org.reload).not_to be_suspended

      call("POST", "/organizations/#{org.key}/actions/unsuspend")
      expect(response).to have_http_status(:conflict)

      call("POST", path)
      expect(response).to have_http_status(:ok)
      call("POST", path)
      expect(response).to have_http_status(:conflict)
      expect(error_code).to eq("conflict")
    end

    it "set_plan sets the plan override and clears it" do
      org = create(:organization)
      plan = create(:plan, name: "Enterprise")

      body = call("POST", "/organizations/#{org.key}/actions/set_plan", { input: { plan: plan.key } })
      expect(response).to have_http_status(:ok)
      expect(body["item"]["values"]["plan_override"]).to eq("id" => plan.key, "label" => "Enterprise")
      expect(org.reload.plan).to eq(plan)
      expect(last_audit).to have_attributes(action: SaasAuditLog::ACTION_ORG_PLAN)
      expect(last_audit.metadata).to include("plan" => "Enterprise")

      call("POST", "/organizations/#{org.key}/actions/set_plan", { input: { plan: nil } })
      expect(response).to have_http_status(:ok)
      expect(org.reload.plan).to be_nil
    end

    it "set_plan takes only a real plan" do
      org = create(:organization)
      plan = create(:plan)

      [ "plan_nothere", plan.id, plan.name, org.key ].each do |value|
        body = call("POST", "/organizations/#{org.key}/actions/set_plan", { input: { plan: value } })
        expect(response).to have_http_status(:unprocessable_content), value.to_s
        expect(body["error"]["fields"].keys).to eq(%w[plan])
      end
      expect(org.reload.plan).to be_nil
    end

    it "wipe deletes the organization and keeps who it was in the audit row" do
      org = create(:organization, name: "Doomed", domain: "doomed.test")
      create(:membership, organization: org)

      body = call("POST", "/organizations/#{org.key}/actions/wipe")
      expect(response).to have_http_status(:ok)
      expect(body).to eq("message" => "Doomed was deleted with all of its data")
      expect(Organization.find_by(id: org.id)).to be_nil
      expect(last_audit).to have_attributes(action: SaasAuditLog::ACTION_ORG_WIPE, target_key: nil)
      expect(last_audit.metadata).to include("key" => org.key, "name" => "Doomed", "domain" => "doomed.test",
                                             "operator" => "ops@example.com")
    end

    it "wipe refuses an input, and never reaches a personal workspace" do
      org = create(:organization)
      personal = Organization.personal_for(create(:user))

      call("POST", "/organizations/#{org.key}/actions/wipe", { input: { confirm: true } })
      expect(response).to have_http_status(:unprocessable_content)
      call("POST", "/organizations/#{personal.key}/actions/wipe")
      expect(response).to have_http_status(:not_found)
      expect(Organization.where(id: [ org.id, personal.id ]).count).to eq(2)
    end
  end

  # ── Memberships, domains, plans ──────────────────────────────────────────────

  describe "memberships" do
    it "lists memberships of team organizations, and filters by organization, user, role and status" do
      acme = create(:organization, name: "Acme")
      beta = create(:organization, name: "Beta")
      ana = create(:user, display_name: "Ana", billing_email: "ana@x.test")
      owner = create(:membership, user: ana, organization: acme, role: "owner")
      create(:mailbox, membership: owner, domain: acme.default_domain, local_part: "ana")
      disabled = create(:membership, organization: acme, status: Membership::STATUS_DISABLED)
      elsewhere = create(:membership, user: ana, organization: beta)
      Organization.personal_for(ana)

      body = call("GET", "/memberships")
      expect(response).to have_http_status(:ok)
      expect(body["items"].map { |i| i["id"] }).to match_array([ owner, disabled, elsewhere ].map(&:key))
      item = body["items"].find { |i| i["id"] == owner.key }
      expect(item["values"]).to include(
        "name" => "Ana", "email" => "ana@x.test", "user" => { "id" => ana.key, "label" => "Ana" },
        "organization" => { "id" => acme.key, "label" => "Acme" }, "role" => "owner", "status" => "active",
        "addresses" => [ "ana@#{acme.default_domain.name}" ]
      )
      expect(item["actions"]).to eq(%w[remove])

      ids = ->(query) { call("GET", "/memberships?#{query}")["items"].map { |i| i["id"] } }
      expect(ids.call("filter[organization]=#{acme.key}")).to match_array([ owner.key, disabled.key ])
      expect(ids.call("filter[user]=#{ana.key}")).to match_array([ owner.key, elsewhere.key ])
      expect(ids.call("filter[role]=owner,admin")).to eq([ owner.key ])
      expect(ids.call("filter[status]=disabled&filter[organization]=#{acme.key}")).to eq([ disabled.key ])
      expect(ids.call("q=ana@x")).to match_array([ owner.key, elsewhere.key ])
      expect(call("GET", "/memberships/#{disabled.key}")).to include("id" => disabled.key)
    end

    it "remove takes the person out of that organization only" do
      user = create(:user, display_name: "Ana")
      org = create(:organization, name: "Acme")
      leaving = create(:membership, user: user, organization: org)
      staying = create(:membership, user: user)
      create(:session, user: user)

      body = call("POST", "/memberships/#{leaving.key}/actions/remove",
                  { input: { data_handling: "archive", alias_handling: "bounce" } })
      expect(response).to have_http_status(:ok)
      expect(body).to eq("message" => "Ana was removed from Acme")
      expect(Membership.find_by(id: leaving.id)).to be_nil
      expect(staying.reload).to be_persisted
      expect(user.sessions.count).to eq(0)
      expect(last_audit).to have_attributes(action: SaasAuditLog::ACTION_ORG_MEMBER_REMOVE, target_key: org.key)
      expect(last_audit.metadata).to include("user" => user.key)
    end

    it "remove refuses without its inputs" do
      membership = create(:membership)

      body = call("POST", "/memberships/#{membership.key}/actions/remove")
      expect(response).to have_http_status(:unprocessable_content)
      expect(body["error"]["fields"]).to eq("data_handling" => "is required", "alias_handling" => "is required")
      expect(membership.reload).to be_persisted
    end
  end

  describe "domains" do
    it "lists and shows domains, by organization" do
      acme = create(:organization, domain: "acme.test")
      extra = create(:domain, organization: acme, name: "acme-extra.test", status: Domain::STATUS_PENDING_DNS)
      create(:organization, domain: "beta.test")

      body = call("GET", "/domains?filter[organization]=#{acme.key}&sort=name")
      expect(response).to have_http_status(:ok)
      expect(body["items"].map { |i| i["values"]["name"] }).to eq(%w[acme-extra.test acme.test])
      expect(body["items"].first["values"]).to include("status" => "pending_dns",
                                                       "organization" => { "id" => acme.key, "label" => acme.name })
      expect(call("GET", "/domains?filter[status]=pending_dns")["items"].map { |i| i["id"] }).to eq([ extra.key ])
      expect(call("GET", "/domains/#{extra.key}")).to include("id" => extra.key, "actions" => [])
      expect(call("GET", "/domains").fetch("total")).to eq(3)
    end

    it "takes no write" do
      domain = create(:organization).default_domain
      call("PATCH", "/domains/#{domain.key}", { values: { status: "verified" } })
      expect(response).to have_http_status(:not_found)
      call("POST", "/domains/#{domain.key}/actions/verify")
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "plans" do
    it "lists and shows plans, cheapest first" do
      free = Plan.free
      pro = create(:plan, name: "Pro", tier: Plan::TIERS.second, price_cents: 1250, interval: "month",
                          max_collaborators: Plan::UNLIMITED)

      body = call("GET", "/plans")
      expect(response).to have_http_status(:ok)
      expect(body["items"].map { |i| i["id"] }).to eq([ free.key, pro.key ])
      expect(body["items"].second["values"]).to include("name" => "Pro", "tier" => Plan::TIERS.second,
                                                        "price" => "12.50", "interval" => "month")
      expect(call("GET", "/plans?q=pr")["items"].map { |i| i["id"] }).to eq([ pro.key ])
      expect(call("GET", "/plans/#{pro.key}")["values"]).to include("max_domains" => 1, "max_collaborators" => nil,
                                                                 "spam_filter" => false)
    end

    it "takes no write" do
      call("PATCH", "/plans/#{Plan.free.key}", { values: { price: "0.00" } })
      expect(response).to have_http_status(:not_found)
    end
  end

  # ── Waitlist ─────────────────────────────────────────────────────────────────

  describe "waitlist" do
    it "lists signups without the long fields, shows them in full, and has a view per status" do
      pending = create(:waitlist_signup, name: "Pat", industry_note: "We run a bakery")
      invited = create(:waitlist_signup, :invited)
      create(:waitlist_signup, status: WaitlistSignup::STATUS_REGISTERED, user: create(:user))

      body = call("GET", "/waitlist")
      expect(response).to have_http_status(:ok)
      expect(body["total"]).to eq(3)
      item = body["items"].find { |i| i["id"] == pending.key }
      expect(item["values"]).to include("name" => "Pat", "email" => pending.email, "company" => "Acme Co",
                                        "status" => "pending", "invited_at" => nil, "user" => nil)
      expect(item["values"].keys).not_to include("industry_note", "email_services", "social_accounts")
      expect(item["actions"]).to eq(%w[invite])

      shown = call("GET", "/waitlist/#{pending.key}")
      expect(shown["values"]).to include("industry_note" => "We run a bakery",
                                         "email_services" => pending.email_services)

      expect(call("GET", "/waitlist?view=invited")["items"].map { |i| i["id"] }).to eq([ invited.key ])
      expect(call("GET", "/waitlist?filter[status]=pending")["items"].map { |i| i["id"] }).to eq([ pending.key ])
      expect(call("GET", "/waitlist?q=#{pending.email}")["items"].map { |i| i["id"] }).to eq([ pending.key ])
    end

    it "invite mails the link and reveals it once" do
      signup = create(:waitlist_signup, email: "pat@bakery.test")

      body = nil
      expect { body = call("POST", "/waitlist/#{signup.key}/actions/invite") }.to have_enqueued_job(MessyTriggerJob)
      expect(response).to have_http_status(:ok)
      signup.reload
      expect(signup).to have_attributes(status: WaitlistSignup::STATUS_INVITED, invited_by: "ops@example.com")
      expect(body["message"]).to eq("An invitation was mailed to pat@bakery.test")
      expect(body["reveal"]["label"]).to eq("Invitation link")
      expect(body["reveal"]["value"]).to end_with("/signup?invite=#{signup.invite_token}")
      expect(body["item"]["values"]).to include("status" => "invited", "invited_by" => "ops@example.com")
      expect(last_audit).to have_attributes(action: SaasAuditLog::ACTION_WAITLIST_INVITE, target_key: signup.key)
      expect(last_audit.metadata).to include("email" => "pat@bakery.test", "operator" => "ops@example.com")
    end

    it "invite refuses a signup that already has an account, and an input" do
      registered = create(:waitlist_signup, status: WaitlistSignup::STATUS_REGISTERED)

      expect { call("POST", "/waitlist/#{registered.key}/actions/invite") }.not_to have_enqueued_job(MessyTriggerJob)
      expect(response).to have_http_status(:conflict)
      expect(registered.reload.invite_token).to be_nil

      call("POST", "/waitlist/#{create(:waitlist_signup).key}/actions/invite", { input: { note: "hi" } })
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
