# Hand-built HTTP fixtures for the Disk importers: a stand-in transport that
# answers registered (method, URL) routes and records every call, so the
# suite never reaches a real source.
class FakeImportTransport
  Call = Struct.new(:method, :url, :headers, :body, :pin, keyword_init: true)

  attr_reader :calls

  def initialize
    @routes = []
    @calls = []
  end

  # Answers matching requests with each response in turn, repeating the last.
  # match is a String (the URL must contain it) or a Regexp; a response is
  # { status:, body:, headers: } or a lambda taking the Call.
  def on(method, match, *responses)
    @routes.unshift([method, match, responses])
    self
  end

  def call(method, url, headers: {}, body: nil, io: nil, pin: nil)
    call = Call.new(method: method, url: url, headers: headers, body: body, pin: pin)
    @calls << call
    route = @routes.find { |m, match, _| m == method && (match.is_a?(Regexp) ? match.match?(url) : url.include?(match)) }
    raise "No fixture for #{method.upcase} #{url}" unless route

    spec = route[2].size > 1 ? route[2].shift : route[2].first
    spec = spec.call(call) if spec.respond_to?(:call)
    status = spec.fetch(:status, 200)
    body = spec[:body].is_a?(String) || spec[:body].nil? ? spec[:body].to_s : spec[:body].to_json
    heads = spec.fetch(:headers, {}).transform_keys { |k| k.to_s.downcase }
    response = Disk::Importer::Http::Response.new(status: status, headers: heads, body: body)
    if io && response.ok?
      io.write(body.b)
      response.body = nil
    end
    response
  end

  def requests(match) = calls.select { |c| match.is_a?(Regexp) ? match.match?(c.url) : c.url.include?(match) }
end

RSpec.shared_context "disk import" do
  include_context "disk org"
  include ActiveJob::TestHelper

  let(:transport) { FakeImportTransport.new }

  around do |example|
    keys = %w[GOOGLE MICROSOFT DROPBOX].flat_map do |p|
      %W[DISK_IMPORT_#{p}_CLIENT_ID DISK_IMPORT_#{p}_CLIENT_SECRET DISK_IMPORT_#{p}_ORGS DISK_IMPORT_#{p}_APPROVED]
    end + %w[DISK_IMPORT_GOOGLE_SERVICE_ACCOUNT]
    saved = keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    keys.each { |k| ENV.delete(k) }
    %w[GOOGLE MICROSOFT DROPBOX].each do |p|
      ENV["DISK_IMPORT_#{p}_CLIENT_ID"] = "#{p.downcase}-client"
      ENV["DISK_IMPORT_#{p}_CLIENT_SECRET"] = "#{p.downcase}-secret"
      ENV["DISK_IMPORT_#{p}_ORGS"] = "*"
    end
    example.run
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  before do
    Disk::Importer.transport = transport
    # No live DNS: a provider-supplied host resolves to a public test address
    # unless a spec says otherwise; IP literals stay themselves.
    allow(PrivateAddressGuard).to receive(:resolve).and_wrap_original do |orig, host|
      PrivateAddressGuard.ip_literal?(host) ? orig.call(host) : ["203.0.113.7"]
    end
  end
  after { Disk::Importer.transport = nil }

  def connection_for(membership, provider, reach: Disk::ImportConnection::REACH_MEMBER, **attrs)
    Disk::ImportConnection.create!(organization: membership.organization, membership: membership, provider: provider,
                                   reach: reach, refresh_token: "refresh", access_token: "access",
                                   access_expires_at: 1.hour.from_now, **attrs)
  end

  # A queued personal import into a folder on the member's C:\.
  def personal_import(membership, provider, connection: nil, cursor: nil)
    connection ||= connection_for(membership, provider)
    target = make_folder(c_root(membership), Disk::ImportSource::FOLDER_NAMES[provider])
    Disk::Import.create!(organization: membership.organization, membership: membership, owner: membership,
                         connection: connection, provider: provider, space_kind: Disk::Import::SPACE_PERSONAL,
                         space_id: "personal", space_name: target.name, target_node: target,
                         state: Disk::Import::STATE_RUNNING, cursor: cursor)
  end

  def run_import(import)
    Disk::Importer.for(import).run
    import.reload
  end

  def stored(node) = storage.read_range(node.current_version.storage_key, 0, node.current_version.size_bytes)

  def item_for(import, source_id) = Disk::ImportItem.find_by!(target_node_id: import.target_node_id, source_id: source_id)
end
