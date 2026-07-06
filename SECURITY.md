# Security Policy

mojo-markdown is a pure-Mojo CommonMark parser and HTML renderer with no
network access, no authentication, and no secrets handling — it reads
markdown text and returns rendered HTML or an AST.

## Output is NOT sanitized

Per the [CommonMark spec](https://spec.commonmark.org/), raw inline and
block HTML, as well as `javascript:`, `data:`, and other arbitrary URL
schemes in links and images, pass through to the output **verbatim**.
mojo-markdown does **not** sanitize its output. Rendering untrusted
markdown and inserting the result into a live page is a stored-XSS risk:
an author can embed `<script>`, event-handler attributes, or a
`javascript:` link and it will be emitted unchanged.

If you render markdown from untrusted sources, run the HTML through a
dedicated sanitizer/allow-list (e.g. an equivalent of DOMPurify) before
displaying it. This library deliberately preserves spec-compliant
passthrough rather than sanitizing, so sanitization is the caller's
responsibility.

## Reporting crashes and hangs

Beyond the passthrough behavior above, the remaining risk surface is
malformed or adversarial input causing a crash or hang.

If you find an input that crashes, hangs, or otherwise misbehaves in a
way that looks security-relevant (e.g. out-of-bounds access, unbounded
memory growth), please report it via a
[GitHub issue](https://github.com/conorbronsdon/mojo-markdown/issues),
including the offending document or a minimal reproduction.

This is a personal open-source project maintained on a best-effort
basis — there's no formal SLA for response time, but reports are
welcome and taken seriously.
