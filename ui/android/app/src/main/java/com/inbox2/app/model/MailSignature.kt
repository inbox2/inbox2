package com.inbox2.app.model

import kotlinx.serialization.Serializable

/** The signature that goes under mail from one address (spec 8.1.7; iOS
 *  MailSignature). The API chooses it: `GET orgs/:id/signatures` → `applied[address]`,
 *  with the sender's name and address filled in. `text` starts with "-- ". */
@Serializable
data class MailSignature(val id: String, val html: String, val text: String) {
    /** Without the "-- " line, for the composer's preview. */
    val previewText: String get() = text.removePrefix("-- \n")

    companion object {
        /** The typed body plus `sig`: plain text, and HTML that carries the
         *  signature's formatting and images (data: URIs the server sends as inline parts). */
        fun body(plain: String, sig: MailSignature?): Pair<String, String?> {
            if (sig == null) return plain to null
            val escaped = plain.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            val paragraphs = escaped.split("\n\n").joinToString("") { "<p>${it.replace("\n", "<br>")}</p>" }
            return "$plain\n\n${sig.text}" to "$paragraphs<br><div data-signature=\"${sig.id}\">${sig.html}</div>"
        }
    }
}
