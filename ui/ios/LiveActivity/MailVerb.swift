import Foundation

/// Engine/cloud verbs the widget extension sends, shared with the app's
/// `ConversationAction.verb` (which the extension doesn't compile).
enum MailVerb {
    static let markRead = "mark_read"
    static let archive = "archive"
    static let trash = "trash"
}
