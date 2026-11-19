"""Unit tests for the quoted-reply / signature detector (collapse.py).

Mirrors the behaviour of the web detectors (quoteDetector.js / signatureDetector.js)
ported to the CLI's text pipeline.
"""

from __future__ import annotations

from inbox2_cli.collapse import split_message


def test_quote_by_attribution_line():
    seg = split_message(
        "Thanks, that works.\n\nOn Mon, May 5, 2026 at 9:00 AM Bob <bob@x.com> wrote:\n"
        "> Are you free Monday?\n> Let me know."
    )
    assert seg.body == "Thanks, that works."
    assert seg.has_quote and seg.quoted.startswith("On Mon")
    assert not seg.has_signature


def test_quote_by_original_message_banner():
    seg = split_message("See below.\n\n-----Original Message-----\nFrom: Bob\n\nstuff")
    assert seg.body == "See below."
    assert "-----Original Message-----" in seg.quoted


def test_quote_localized_dutch():
    seg = split_message(
        "Bedankt.\n\nOp 5 mei 2026 om 09:00 schreef Bob Jansen:\n> originele tekst"
    )
    assert seg.body == "Bedankt."
    assert seg.has_quote


def test_quote_by_trailing_blockquote():
    # html2text renders structural quote containers as `>`-prefixed lines.
    seg = split_message("Sounds good.\n\n> previous line one\n> previous line two")
    assert seg.body == "Sounds good."
    assert seg.quoted == "> previous line one\n> previous line two"


def test_signature_by_delimiter():
    seg = split_message("Hi there,\n\nLet's meet.\n\n-- \nJane Doe\nAcme Corp\n555-1234")
    assert seg.body == "Hi there,\n\nLet's meet."
    assert seg.signature.startswith("-- ") and "Jane Doe" in seg.signature
    assert not seg.has_quote


def test_signature_delimiter_guard_rejects_long_block():
    # More than 12 non-empty lines after "-- " → not treated as a signature.
    tail = "\n".join(f"line {i}" for i in range(15))
    seg = split_message("intro line\n-- \n" + tail)
    assert not seg.has_signature


def test_signature_delimiter_not_on_first_line():
    # Delimiter at line 0 would wrap the whole message — guarded. (No contact
    # info follows, so the heuristic doesn't fire either.)
    seg = split_message("-- \nplease reply inline above\nthanks everyone")
    assert not seg.has_signature


def test_signature_contact_block_heuristic():
    seg = split_message("Thank you,\n\nStephanie Sever\nEnronOnline\n713-853-3465")
    assert seg.has_signature
    assert "Stephanie Sever" in seg.signature and "713-853-3465" in seg.signature
    # The sign-off stays in the body (matches the web algorithm).
    assert seg.body == "Thank you,"


def test_signature_inside_quote_not_separately_detected():
    # Ordering: quotes are detected first; a signature buried in the quoted reply
    # is not pulled out as the current message's signature.
    seg = split_message(
        "My reply.\n\nOn Mon, May 4 2026 at 9am Their Name wrote:\n"
        "> Original body\n> -- \n> Their Name\n> 555-1234"
    )
    assert seg.body == "My reply."
    assert not seg.has_signature
    assert "Their Name" in seg.quoted


def test_plain_message_has_no_collapse():
    seg = split_message("Just a normal message with no quote and no signature here.")
    assert not seg.has_quote and not seg.has_signature
    assert seg.body == "Just a normal message with no quote and no signature here."


def test_empty_message():
    seg = split_message("")
    assert seg.body == "" and not seg.has_quote and not seg.has_signature
