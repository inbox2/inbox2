"""Unit tests for the inline body renderer (bodyrender.py).

The critical property is that each returned link span addresses exactly the
right characters of the rendered Text, so the widget can highlight links inline.
"""

from __future__ import annotations

from inbox2_cli.bodyrender import render_body


def test_markdown_link_span_addresses_label():
    text, links = render_body("See [our site](http://example.com/x) now.")
    assert text.plain == "See our site now."
    assert len(links) == 1
    start, end, url = links[0]
    assert text.plain[start:end] == "our site"
    assert url == "http://example.com/x"


def test_angle_bracketed_target():
    _, links = render_body("Docs: [d](<https://example.com/d>)")
    assert links[0][2] == "https://example.com/d"


def test_bare_url_and_mailto_spans():
    text, links = render_body("ping mailto:a@b.com or https://b.com/p please")
    urls = [u for _, _, u in links]
    assert "mailto:a@b.com" in urls and "https://b.com/p" in urls
    for start, end, url in links:
        # The span addresses the link's own text in the output.
        assert text.plain[start:end] in url or url.endswith(text.plain[start:end])


def test_www_gets_scheme_and_trailing_punct_trimmed():
    text, links = render_body("Home www.example.org, thanks.")
    start, end, url = links[0]
    assert text.plain[start:end] == "www.example.org"
    assert url == "http://www.example.org"


def test_bold_and_italic_markers_stripped():
    text, links = render_body("a **bold** and *em* word")
    assert text.plain == "a bold and em word"
    assert links == []


def test_heading_and_list_rendered():
    text, _ = render_body("# Title\n- one\n- two")
    assert "Title" in text.plain
    assert "• one" in text.plain and "• two" in text.plain


def test_markdown_target_not_double_counted():
    text, links = render_body("[x](https://once.com)")
    assert text.plain == "x"
    assert links == [(0, 1, "https://once.com")]


def test_multiple_links_ordered():
    text, links = render_body("[a](http://a.com) then [b](http://b.com)")
    assert [u for _, _, u in links] == ["http://a.com", "http://b.com"]
    # Spans are non-overlapping and in order.
    assert links[0][1] <= links[1][0]


def test_url_inside_italic_is_recognized():
    # html2text wraps a whole paragraph in `_..._` (italic); the URL inside must
    # still be detected and addressable — the reported "link not recognized" bug.
    url = (
        "https://libanonlyceum.wiscollect.nl/app/portal/"
        "b34ea08e-41d3-4361-a4e2-f480a61938e0/invoices/"
        "630ee1f0-3a1e-42d1-bf1d-db0341b0e40b?t=24uqjQcjEOj8K5p9keZOe8a2m0PousSDcByrlHPOFyriq"
    )
    text, links = render_body(f"_Kopieer deze link naar de adresbalk: {url}_")
    assert len(links) == 1
    start, end, found = links[0]
    assert found == url
    assert text.plain[start:end] == url


def test_link_inside_bold_is_recognized():
    text, links = render_body("**Visit [home](http://a.com) now**")
    assert links == [(text.plain.index("home"), text.plain.index("home") + 4, "http://a.com")]


def test_empty_and_none():
    for value in ("", None):
        text, links = render_body(value)
        assert text.plain == "" and links == []
