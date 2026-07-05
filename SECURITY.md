# Security Policy

mojo-markdown is a pure-Mojo CommonMark parser and HTML renderer with no
network access, no authentication, and no secrets handling — it reads
markdown text and returns rendered HTML or an AST. The main risk
surface is malformed or adversarial input causing a crash or hang.

If you find an input that crashes, hangs, or otherwise misbehaves in a
way that looks security-relevant (e.g. out-of-bounds access, unbounded
memory growth), please report it via a
[GitHub issue](https://github.com/conorbronsdon/mojo-markdown/issues),
including the offending document or a minimal reproduction.

This is a personal open-source project maintained on a best-effort
basis — there's no formal SLA for response time, but reports are
welcome and taken seriously.
