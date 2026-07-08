# Changelog

## Unreleased

New `markdown.errors` module (exported from the package), adopting the
error-reporting pattern shared across the mojo-* parser suite:
`line_col(source, offset)` maps a byte offset to a 1-based (line, column)
pair — the column is the 1-based BYTE offset within the line, no UTF-8
decoding — and `parse_error(msg, source, offset)` builds an `Error` reading
`<msg> at line <L>, column <C>: '<snippet>'`, where the snippet is up to
~30 bytes of the offending line centered on the column,
whitespace-trimmed, with `...` where truncated, and never multi-line.

No parser call sites were wired: CommonMark treats every input as valid
markdown, so the parser has no input-error `raise` sites (the container
nesting cap degrades silently rather than raising). The module ships for
suite consistency and for downstream users who validate markdown-adjacent
input themselves.

## 0.1.0 — 2026-07-05

Initial release. CommonMark block parser (ATX/setext headings,
paragraphs, fenced and indented code blocks, blockquotes, ordered and
unordered lists, thematic breaks, HTML blocks, link reference
definitions) and inline parser (code spans, emphasis/strong, links,
images, reference links, autolinks, escapes, entities) with an HTML
renderer. 643 of 652 examples (98.6%) from the CommonMark 0.31.2 spec
test suite pass; the hand-written unit suite passes completely.

Robustness: fuzzing surfaced an unbounded-recursion stack overflow on
deeply nested containers, fixed with a 256-level nesting cap before release.
