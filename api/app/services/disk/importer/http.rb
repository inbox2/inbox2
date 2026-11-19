module Disk
  class Importer
    # The importers' one way out to a source. Answers a Response; with io:,
    # a successful body is streamed into io (never held in memory) and a body
    # shorter than its Content-Length raises Incomplete. Specs swap in a fake
    # (Disk::Importer.transport=), so the suite makes no live calls.
    class Http
      Response = Struct.new(:status, :headers, :body, keyword_init: true) do
        def ok? = status.between?(200, 299)
        def json = @json ||= (body.present? ? JSON.parse(body) : {})
        def header(name) = headers[name.to_s.downcase]
      end
      Incomplete = Class.new(StandardError)

      USER_AGENT = "ISV|inbox2|Disk-Importer/1.0".freeze # the decorated form Microsoft asks for
      METHODS = { get: Net::HTTP::Get, post: Net::HTTP::Post }.freeze

      def call(method, url, headers: {}, body: nil, io: nil, pin: nil)
        uri = URI(url)
        request = METHODS.fetch(method).new(uri)
        { "User-Agent" => USER_AGENT }.merge(headers).each { |k, v| request[k] = v }
        request.body = body if body
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", ipaddr: pin, open_timeout: 15, read_timeout: 120) do |http|
          http.request(request) do |res|
            heads = res.each_header.to_h { |k, v| [k.downcase, v] }
            status = res.code.to_i
            if io && status.between?(200, 299)
              written = 0
              res.read_body { |chunk| written += io.write(chunk) }
              expected = heads["content-length"]&.to_i
              raise Incomplete, "got #{written} of #{expected} bytes" if expected && written != expected
              return Response.new(status: status, headers: heads, body: nil)
            end
            return Response.new(status: status, headers: heads, body: res.read_body)
          end
        end
      end
    end
  end
end
