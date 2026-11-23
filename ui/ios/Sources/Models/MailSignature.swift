import Foundation

/// The signature that goes under mail from one address (spec 8.1.7). The API
/// chooses it: `GET orgs/:id/signatures` → `applied[address]`, with the
/// sender's name and address already filled in. `text` starts with "-- ".
struct MailSignature: Decodable, Equatable {
    let id: String
    let html: String
    let text: String

    /// The signature without its "-- " line, for the composer's preview.
    var previewText: String {
        text.hasPrefix("-- \n") ? String(text.dropFirst(4)) : text
    }

    /// The typed body plus this signature: plain text, and HTML that carries
    /// the signature's formatting and images (data: URIs the server sends as
    /// inline parts).
    static func body(plain: String, signature: MailSignature?) -> (plain: String, html: String?) {
        guard let s = signature else { return (plain, nil) }
        let escaped = plain
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let paragraphs = escaped.components(separatedBy: "\n\n")
            .map { "<p>\($0.replacingOccurrences(of: "\n", with: "<br>"))</p>" }
            .joined()
        return ("\(plain)\n\n\(s.text)", "\(paragraphs)<br><div data-signature=\"\(s.id)\">\(s.html)</div>")
    }
}
