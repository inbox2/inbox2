"""Plain-text quote / forward builder tests."""

from __future__ import annotations

from inbox2_cli import drafts


MSG = {
    "from_address": "bob@x.com",
    "to_address": "me@work.com",
    "cc_address": "ann@x.com",
    "subject": "Hello there",
    "body_plain": "Line one\nLine two",
    "created_at": "2026-05-30T10:00:00Z",
}


def test_quote_reply_prefixes_lines():
    quoted = drafts.quote_reply(MSG)
    assert "> Line one" in quoted
    assert "> Line two" in quoted
    assert "bob@x.com wrote:" in quoted


def test_forward_one_has_delimiter_and_headers():
    fwd = drafts.forward_one(MSG)
    assert "---------- Forwarded message ----------" in fwd
    assert "From: bob@x.com" in fwd
    assert "Subject: Hello there" in fwd
    assert "Line one" in fwd


def test_reply_subject_idempotent():
    assert drafts.reply_subject("Hello") == "Re: Hello"
    assert drafts.reply_subject("Re: Hello") == "Re: Hello"


def test_forward_subject_idempotent():
    assert drafts.forward_subject("Hello") == "Fwd: Hello"
    assert drafts.forward_subject("Fwd: Hello") == "Fwd: Hello"


def test_reply_all_excludes_self():
    rcpts = drafts.reply_all_recipients(MSG, "me@work.com")
    assert "bob@x.com" in rcpts
    assert "ann@x.com" in rcpts
    assert "me@work.com" not in rcpts


def test_message_text_prefers_plain():
    from inbox2_cli.htmltext import message_text

    assert message_text({"body_plain": "hello", "body_html": "<p>ignored</p>"}) == "hello"


def test_message_text_renders_html_when_no_plain():
    from inbox2_cli.htmltext import message_text

    out = message_text({"body_plain": "", "body_html": "<p>Lunch at <b>noon</b>? <script>x</script></p>"})
    assert "Lunch at" in out
    assert "noon" in out
    assert "<" not in out  # tags stripped
    assert "script" not in out  # style/script dropped
