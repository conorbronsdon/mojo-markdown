"""HTML renderer: walks the block tree and emits HTML.

Output conventions follow the CommonMark reference renderer: one block
element per line, tight list items render their paragraphs inline, and
code/text content is entity-escaped.
"""

from markdown.block import (
    B_BREAK,
    B_CODE,
    B_DOCUMENT,
    B_HEADING,
    B_HTML,
    B_ITEM,
    B_LIST,
    B_PARAGRAPH,
    B_QUOTE,
    Block,
    BlockTree,
    parse_blocks,
)
from markdown.common import (
    SPACE,
    TAB,
    escape_html,
    resolve_refs,
    sub_string,
)
from markdown.inline import render_inlines


def _render_item(tree: BlockTree, idx: Int, tight: Bool) raises -> String:
    var body = String()
    for k in range(len(tree.nodes[idx].children)):
        var child = tree.nodes[idx].children[k]
        if tight and tree.nodes[child].kind == B_PARAGRAPH:
            body += render_inlines(tree.nodes[child].text, tree.refs)
        else:
            if not body.endswith("\n"):
                body += "\n"
            body += _render_block(tree, child, tight)
    return String("<li>") + body + "</li>\n"


def _render_block(tree: BlockTree, idx: Int, tight: Bool) raises -> String:
    var kind = tree.nodes[idx].kind
    if kind == B_PARAGRAPH:
        if tight:
            return render_inlines(tree.nodes[idx].text, tree.refs)
        return (
            String("<p>")
            + render_inlines(tree.nodes[idx].text, tree.refs)
            + "</p>\n"
        )
    if kind == B_HEADING:
        var level = String(tree.nodes[idx].level)
        return (
            String("<h")
            + level
            + ">"
            + render_inlines(tree.nodes[idx].text, tree.refs)
            + "</h"
            + level
            + ">\n"
        )
    if kind == B_CODE:
        var out = String("<pre><code")
        var info = tree.nodes[idx].info
        if info.byte_length() > 0:
            var ib = info.as_bytes()
            var word_end = 0
            while (
                word_end < len(ib)
                and ib[word_end] != SPACE
                and (ib[word_end] != TAB)
            ):
                word_end += 1
            out += ' class="language-'
            out += escape_html(resolve_refs(sub_string(info, 0, word_end)))
            out += '"'
        out += ">"
        out += escape_html(tree.nodes[idx].text)
        out += "</code></pre>\n"
        return out^
    if kind == B_HTML:
        return tree.nodes[idx].text.copy()
    if kind == B_BREAK:
        return String("<hr />\n")
    if kind == B_QUOTE:
        return (
            String("<blockquote>\n")
            + _render_children(tree, idx, False)
            + "</blockquote>\n"
        )
    if kind == B_LIST:
        var items = String()
        for k in range(len(tree.nodes[idx].children)):
            items += _render_item(
                tree, tree.nodes[idx].children[k], tree.nodes[idx].tight
            )
        if tree.nodes[idx].ordered:
            var open_tag = String("<ol>\n")
            if tree.nodes[idx].level != 1:
                open_tag = (
                    String('<ol start="')
                    + String(tree.nodes[idx].level)
                    + '">\n'
                )
            return open_tag + items + "</ol>\n"
        return String("<ul>\n") + items + "</ul>\n"
    if kind == B_ITEM:
        return _render_item(tree, idx, tight)
    return _render_children(tree, idx, False)


def _render_children(tree: BlockTree, idx: Int, tight: Bool) raises -> String:
    var out = String()
    for k in range(len(tree.nodes[idx].children)):
        out += _render_block(tree, tree.nodes[idx].children[k], tight)
    return out^


def render_html(source: String) raises -> String:
    """Render CommonMark-flavored markdown source to HTML."""
    var tree = parse_blocks(source)
    return _render_children(tree, tree.root, False)
