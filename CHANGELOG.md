# Changelog

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
