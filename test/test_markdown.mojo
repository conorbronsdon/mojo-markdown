from std.testing import assert_equal, assert_true, TestSuite

from markdown import render_html


def test_atx_heading() raises:
    assert_equal(render_html("# Hello"), "<h1>Hello</h1>\n")
    assert_equal(render_html("###### deep"), "<h6>deep</h6>\n")
    assert_equal(render_html("####### too deep"), "<p>####### too deep</p>\n")


def test_atx_closing_hashes() raises:
    assert_equal(render_html("## foo ##"), "<h2>foo</h2>\n")
    assert_equal(render_html("# foo#"), "<h1>foo#</h1>\n")
    assert_equal(render_html("### foo ### b"), "<h3>foo ### b</h3>\n")


def test_paragraph() raises:
    assert_equal(render_html("hello world"), "<p>hello world</p>\n")
    assert_equal(
        render_html("line one\nline two"), "<p>line one\nline two</p>\n"
    )


def test_paragraph_separation() raises:
    assert_equal(render_html("aaa\n\nbbb"), "<p>aaa</p>\n<p>bbb</p>\n")


def test_setext_heading() raises:
    assert_equal(render_html("Title\n====="), "<h1>Title</h1>\n")
    assert_equal(render_html("Sub\n---"), "<h2>Sub</h2>\n")


def test_thematic_break() raises:
    assert_equal(render_html("---"), "<hr />\n")
    assert_equal(render_html("* * *"), "<hr />\n")
    assert_equal(render_html("_____"), "<hr />\n")


def test_fenced_code() raises:
    assert_equal(
        render_html("```\ncode here\n```"),
        "<pre><code>code here\n</code></pre>\n",
    )


def test_fenced_code_info_string() raises:
    assert_equal(
        render_html("```mojo\ndef main():\n```"),
        '<pre><code class="language-mojo">def main():\n</code></pre>\n',
    )


def test_tilde_fence() raises:
    assert_equal(
        render_html("~~~\n<escaped> & such\n~~~"),
        "<pre><code>&lt;escaped&gt; &amp; such\n</code></pre>\n",
    )


def test_unclosed_fence_runs_to_end() raises:
    assert_equal(
        render_html("```\nno closer"),
        "<pre><code>no closer\n</code></pre>\n",
    )


def test_indented_code() raises:
    assert_equal(
        render_html("    indented\n    block"),
        "<pre><code>indented\nblock\n</code></pre>\n",
    )


def test_blockquote() raises:
    assert_equal(
        render_html("> quoted"),
        "<blockquote>\n<p>quoted</p>\n</blockquote>\n",
    )


def test_nested_blockquote() raises:
    assert_equal(
        render_html("> > inner"),
        "<blockquote>\n<blockquote>\n<p>inner</p>\n</blockquote>\n"
        + "</blockquote>\n",
    )


def test_blockquote_lazy_continuation() raises:
    assert_equal(
        render_html("> lazy\ncontinuation"),
        "<blockquote>\n<p>lazy\ncontinuation</p>\n</blockquote>\n",
    )


def test_unordered_list() raises:
    assert_equal(
        render_html("- one\n- two"),
        "<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n",
    )


def test_ordered_list_with_start() raises:
    assert_equal(
        render_html("3. c\n4. d"),
        '<ol start="3">\n<li>c</li>\n<li>d</li>\n</ol>\n',
    )


def test_nested_list() raises:
    assert_equal(
        render_html("- a\n  - b"),
        "<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul>\n</li>\n</ul>\n",
    )


def test_loose_list() raises:
    assert_equal(
        render_html("- a\n\n- b"),
        "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n",
    )


def test_code_span() raises:
    assert_equal(
        render_html("use `x = 1` here"), "<p>use <code>x = 1</code> here</p>\n"
    )


def test_double_backtick_code_span() raises:
    assert_equal(render_html("`` a`b ``"), "<p><code>a`b</code></p>\n")


def test_emphasis() raises:
    assert_equal(render_html("*foo*"), "<p><em>foo</em></p>\n")
    assert_equal(render_html("_foo_"), "<p><em>foo</em></p>\n")


def test_strong() raises:
    assert_equal(render_html("**foo**"), "<p><strong>foo</strong></p>\n")
    assert_equal(render_html("__foo__"), "<p><strong>foo</strong></p>\n")


def test_em_strong_nested() raises:
    assert_equal(
        render_html("***foo***"),
        "<p><em><strong>foo</strong></em></p>\n",
    )


def test_intraword_underscore_is_literal() raises:
    assert_equal(render_html("foo_bar_baz"), "<p>foo_bar_baz</p>\n")


def test_intraword_star_emphasis() raises:
    assert_equal(render_html("foo*bar*baz"), "<p>foo<em>bar</em>baz</p>\n")


def test_link() raises:
    assert_equal(
        render_html("[text](/url)"), '<p><a href="/url">text</a></p>\n'
    )


def test_link_with_title() raises:
    assert_equal(
        render_html('[text](/url "the title")'),
        '<p><a href="/url" title="the title">text</a></p>\n',
    )


def test_link_with_emphasis_inside() raises:
    assert_equal(
        render_html("[*em* text](/u)"),
        '<p><a href="/u"><em>em</em> text</a></p>\n',
    )


def test_image() raises:
    assert_equal(
        render_html("![alt text](img.png)"),
        '<p><img src="img.png" alt="alt text" /></p>\n',
    )


def test_image_alt_is_plain_text() raises:
    assert_equal(
        render_html("![foo *bar*](train.jpg)"),
        '<p><img src="train.jpg" alt="foo bar" /></p>\n',
    )


def test_image_alt_raw_html_gt_no_breakout() raises:
    # A raw `>` inside a quoted attribute of raw HTML in the image
    # description must not terminate the tag early and break out of the
    # generated alt="…" attribute. Raw HTML contributes no alt text, so
    # only the trailing literal `x` survives.
    assert_equal(
        render_html(String('![<span title="a>b">x](/i.png)')),
        '<p><img src="/i.png" alt="x" /></p>\n',
    )
    # Single-quoted attribute value is handled the same way.
    assert_equal(
        render_html(String("![<span title='a>b'>x](/i.png)")),
        '<p><img src="/i.png" alt="x" /></p>\n',
    )
    # A nested <img> still contributes its alt text, even when a later
    # attribute contains a raw `>`.
    assert_equal(
        render_html(String('![<img alt="D" title="a>b">z](/i.png)')),
        '<p><img src="/i.png" alt="Dz" /></p>\n',
    )


def test_autolink() raises:
    assert_equal(
        render_html("<https://example.com>"),
        '<p><a href="https://example.com">https://example.com</a></p>\n',
    )


def test_email_autolink() raises:
    assert_equal(
        render_html("<a@b.example.com>"),
        '<p><a href="mailto:a@b.example.com">a@b.example.com</a></p>\n',
    )


def test_backslash_escape() raises:
    assert_equal(render_html("\\*not em\\*"), "<p>*not em*</p>\n")


def test_hard_break_spaces() raises:
    assert_equal(render_html("foo  \nbar"), "<p>foo<br />\nbar</p>\n")


def test_hard_break_backslash() raises:
    assert_equal(render_html("foo\\\nbar"), "<p>foo<br />\nbar</p>\n")


def test_soft_break() raises:
    assert_equal(render_html("foo\nbar"), "<p>foo\nbar</p>\n")


def test_entity_escaping_in_text() raises:
    assert_equal(
        render_html('AT&T says 1 < 2 & "quotes"'),
        "<p>AT&amp;T says 1 &lt; 2 &amp; &quot;quotes&quot;</p>\n",
    )


def test_numeric_entity() raises:
    assert_equal(render_html("&#35; &#x22;"), "<p># &quot;</p>\n")


def test_named_entity() raises:
    assert_equal(render_html("&amp; &copy;"), "<p>&amp; ©</p>\n")


def test_raw_inline_html() raises:
    assert_equal(
        render_html('foo <span class="x">bar</span>'),
        '<p>foo <span class="x">bar</span></p>\n',
    )


def test_html_block() raises:
    assert_equal(
        render_html("<div>\n*not em*\n</div>"),
        "<div>\n*not em*\n</div>\n",
    )


def test_url_encoding() raises:
    assert_equal(
        render_html("[a](/my uri)"),
        "<p>[a](/my uri)</p>\n",
    )
    assert_equal(
        render_html("[a](</my uri>)"),
        '<p><a href="/my%20uri">a</a></p>\n',
    )


def test_reference_link() raises:
    assert_equal(
        render_html('[foo][bar]\n\n[bar]: /url "t"'),
        '<p><a href="/url" title="t">foo</a></p>\n',
    )


def test_collapsed_and_shortcut_reference() raises:
    assert_equal(
        render_html("[foo][]\n\n[FOO]: /url"),
        '<p><a href="/url">foo</a></p>\n',
    )
    assert_equal(
        render_html("[foo]\n\n[foo]: /url"),
        '<p><a href="/url">foo</a></p>\n',
    )


def test_undefined_reference_is_literal() raises:
    assert_equal(render_html("[foo][nope]"), "<p>[foo][nope]</p>\n")


def test_utf8_passthrough() raises:
    assert_equal(
        render_html("# café — naïve 中文"),
        "<h1>café — naïve 中文</h1>\n",
    )


def test_list_item_with_multiple_blocks() raises:
    assert_equal(
        render_html("- para\n\n      code"),
        "<ul>\n<li>\n<p>para</p>\n<pre><code>code\n</code></pre>\n"
        + "</li>\n</ul>\n",
    )


def test_blockquote_containing_list() raises:
    assert_equal(
        render_html("> - a\n> - b"),
        "<blockquote>\n<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n"
        + "</blockquote>\n",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
