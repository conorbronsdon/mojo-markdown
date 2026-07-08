"""Inline parser: renders span-level markdown to HTML.

Handles backslash escapes, code spans, emphasis and strong emphasis with a
delimiter stack (simplified flanking rules over ASCII classes), inline
links and images, autolinks, raw inline HTML passthrough, entity
references, and hard/soft line breaks.

Links and images use a bracket delimiter stack with active/inactive flags
(the CommonMark algorithm): a `]` closes against the nearest active `[` or
`![`; when a link is formed, all earlier `[` openers are deactivated so a
link cannot nest inside another link's text.
"""

from markdown.common import (
    AMP,
    BACKTICK,
    BANG,
    BSLASH,
    GT,
    LBRACKET,
    LPAREN,
    LT,
    NEWLINE,
    QUOTE,
    RBRACKET,
    RPAREN,
    SEMI,
    SLASH,
    SPACE,
    SQUOTE,
    STAR,
    TAB,
    UNDERSCORE,
    RefMap,
    append_codepoint,
    byte_char,
    codepoint_at,
    codepoint_before,
    encode_url,
    escape_html,
    is_uni_punct,
    is_uni_space,
    scan_html_tag,
    is_alnum_byte,
    is_alpha_byte,
    is_digit_byte,
    is_punct_byte,
    is_space_byte,
    match_entity,
    resolve_refs,
    sub_string,
    to_lower_byte,
)


@fieldwise_init
struct _Chunk(Copyable, Movable):
    """One token in the inline stream: rendered HTML, a delimiter run, or a
    bracket opener awaiting link resolution."""

    var html: String
    var is_delim: Bool
    var ch: UInt8
    var count: Int
    var orig_count: Int
    var can_open: Bool
    var can_close: Bool
    var open_tags: List[Int]
    var close_tags: List[Int]
    var is_bracket: Bool
    var active: Bool
    var is_image: Bool
    var pos: Int

    @staticmethod
    def text(var html: String) -> _Chunk:
        return _Chunk(
            html^,
            False,
            UInt8(0),
            0,
            0,
            False,
            False,
            List[Int](),
            List[Int](),
            False,
            False,
            False,
            0,
        )

    @staticmethod
    def delim(ch: UInt8, count: Int, can_open: Bool, can_close: Bool) -> _Chunk:
        return _Chunk(
            String(),
            True,
            ch,
            count,
            count,
            can_open,
            can_close,
            List[Int](),
            List[Int](),
            False,
            False,
            False,
            0,
        )

    @staticmethod
    def bopen(pos: Int, is_image: Bool) -> _Chunk:
        var lit = String("[")
        if is_image:
            lit = String("![")
        return _Chunk(
            lit^,
            False,
            UInt8(0),
            0,
            0,
            False,
            False,
            List[Int](),
            List[Int](),
            True,
            True,
            is_image,
            pos,
        )


def _flush_text(mut chunks: List[_Chunk], mut text: String):
    if text.byte_length() > 0:
        chunks.append(_Chunk.text(escape_html(text)))
        text = String()


def _code_span(
    s: String, start: Int, mut chunks: List[_Chunk], mut text: String
) -> Int:
    """Handle a backtick run at `start`; returns the new scan position."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    var m = 0
    while start + m < n and bytes[start + m] == BACKTICK:
        m += 1
    # Find a closing run of exactly the same length.
    var j = start + m
    var close = -1
    while j < n:
        if bytes[j] == BACKTICK:
            var r = 0
            while j + r < n and bytes[j + r] == BACKTICK:
                r += 1
            if r == m:
                close = j
                break
            j += r
        else:
            j += 1
    if close == -1:
        for _ in range(m):
            text += "`"
        return start + m
    _flush_text(chunks, text)
    # Content: newlines become spaces; strip one space from each end when
    # both ends are spaces and the content is not all spaces.
    var content = String()
    for k in range(start + m, close):
        if bytes[k] == NEWLINE:
            content += " "
        else:
            content += byte_char(bytes[k])
    var cb = content.as_bytes()
    var strip = False
    if len(cb) >= 2 and cb[0] == SPACE and cb[len(cb) - 1] == SPACE:
        for k in range(len(cb)):
            if cb[k] != SPACE:
                strip = True
                break
    if strip:
        content = sub_string(content, 1, content.byte_length() - 1)
    chunks.append(
        _Chunk.text(String("<code>") + escape_html(content) + "</code>")
    )
    return close + m


def _delimiter_run(
    s: String, start: Int, mut chunks: List[_Chunk], mut text: String
) -> Int:
    """Handle a * or _ run at `start` with simplified flanking rules."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    var ch = bytes[start]
    var run = 0
    while start + run < n and bytes[start + run] == ch:
        run += 1
    var prev_cp = codepoint_before(s, start)
    var next_cp = codepoint_at(s, start + run)
    var prev_space = is_uni_space(prev_cp)
    var prev_punct = is_uni_punct(prev_cp)
    var next_space = is_uni_space(next_cp)
    var next_punct = is_uni_punct(next_cp)
    var left = (not next_space) and (
        (not next_punct) or prev_space or prev_punct
    )
    var right = (not prev_space) and (
        (not prev_punct) or next_space or next_punct
    )
    var can_open: Bool
    var can_close: Bool
    if ch == STAR:
        can_open = left
        can_close = right
    else:
        can_open = left and ((not right) or prev_punct)
        can_close = right and ((not left) or next_punct)
    _flush_text(chunks, text)
    chunks.append(_Chunk.delim(ch, run, can_open, can_close))
    return start + run


def _try_autolink_uri(s: String, start: Int) -> Int:
    """End index (past '>') of a URI autolink at `start` ('<'), or 0."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    var i = start + 1
    if i >= n or not is_alpha_byte(bytes[i]):
        return 0
    var scheme_len = 1
    i += 1
    while i < n and scheme_len < 32:
        var b = bytes[i]
        if (
            is_alnum_byte(b)
            or b == UInt8(0x2B)
            or b == UInt8(0x2D)
            or (b == UInt8(0x2E))
        ):
            scheme_len += 1
            i += 1
        else:
            break
    if scheme_len < 2 or i >= n or bytes[i] != UInt8(0x3A):
        return 0
    i += 1
    while i < n:
        var b = bytes[i]
        if b == GT:
            return i + 1
        if b <= SPACE or b == LT:
            return 0
        i += 1
    return 0


def _try_autolink_email(s: String, start: Int) -> Int:
    """End index (past '>') of an email autolink at `start` ('<'), or 0."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    var i = start + 1
    var local_len = 0
    comptime local_extra: StaticString = ".!#$%&'*+/=?^_`{|}~-"
    while i < n:
        var b = bytes[i]
        if is_alnum_byte(b):
            local_len += 1
            i += 1
            continue
        var extra = local_extra.as_bytes()
        var ok = False
        for k in range(len(extra)):
            if extra[k] == b:
                ok = True
                break
        if ok:
            local_len += 1
            i += 1
        else:
            break
    if local_len == 0 or i >= n or bytes[i] != UInt8(0x40):
        return 0
    i += 1
    var label_len = 0
    var has_domain = False
    while i < n:
        var b = bytes[i]
        if is_alnum_byte(b) or (b == UInt8(0x2D) and label_len > 0):
            label_len += 1
            has_domain = True
            i += 1
        elif b == UInt8(0x2E) and label_len > 0:
            label_len = 0
            i += 1
        elif b == GT and has_domain and label_len > 0:
            return i + 1
        else:
            return 0
    return 0


def _angle(
    s: String, start: Int, mut chunks: List[_Chunk], mut text: String
) raises -> Int:
    """Handle '<': autolink or raw HTML. Returns new position or `start`."""
    var uri_end = _try_autolink_uri(s, start)
    if uri_end > 0:
        var raw = sub_string(s, start + 1, uri_end - 1)
        _flush_text(chunks, text)
        var html = String('<a href="')
        html += escape_html(encode_url(raw))
        html += '">'
        html += escape_html(raw)
        html += "</a>"
        chunks.append(_Chunk.text(html^))
        return uri_end
    var email_end = _try_autolink_email(s, start)
    if email_end > 0:
        var raw = sub_string(s, start + 1, email_end - 1)
        _flush_text(chunks, text)
        var html = String('<a href="mailto:')
        html += escape_html(encode_url(raw))
        html += '">'
        html += escape_html(raw)
        html += "</a>"
        chunks.append(_Chunk.text(html^))
        return email_end
    var tag_len = scan_html_tag(s, start)
    if tag_len > 0:
        _flush_text(chunks, text)
        chunks.append(_Chunk.text(sub_string(s, start, start + tag_len)))
        return start + tag_len
    return start


def _skip_link_ws(s: String, start: Int) -> Int:
    var bytes = s.as_bytes()
    var i = start
    while i < len(bytes) and (
        bytes[i] == SPACE or bytes[i] == NEWLINE or bytes[i] == TAB
    ):
        i += 1
    return i


@fieldwise_init
struct _LinkSuffix(Copyable, Movable):
    var ok: Bool
    var end: Int
    var dest: String
    var title: String
    var has_title: Bool

    @staticmethod
    def none() -> _LinkSuffix:
        return _LinkSuffix(False, 0, String(), String(), False)


def _parse_inline_suffix(s: String, lparen: Int) -> _LinkSuffix:
    """Parse `(dest "title")` starting at `lparen`."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    var p = lparen + 1
    p = _skip_link_ws(s, p)
    var dest_raw: String
    if p < n and bytes[p] == LT:
        p += 1
        var ds = p
        while p < n and bytes[p] != GT:
            if bytes[p] == NEWLINE or bytes[p] == LT:
                return _LinkSuffix.none()
            if bytes[p] == BSLASH and p + 1 < n:
                p += 1
            p += 1
        if p >= n:
            return _LinkSuffix.none()
        dest_raw = sub_string(s, ds, p)
        p += 1
    else:
        var ds = p
        var paren_depth = 0
        while p < n:
            var b = bytes[p]
            if is_space_byte(b) or b < SPACE:
                break
            if b == BSLASH and p + 1 < n and is_punct_byte(bytes[p + 1]):
                p += 2
                continue
            if b == LPAREN:
                paren_depth += 1
            elif b == RPAREN:
                if paren_depth == 0:
                    break
                paren_depth -= 1
            p += 1
        if paren_depth != 0:
            return _LinkSuffix.none()
        dest_raw = sub_string(s, ds, p)
    var after_dest = p
    p = _skip_link_ws(s, p)
    var had_ws = p > after_dest
    var title_raw = String()
    var has_title = False
    if p < n and (
        bytes[p] == QUOTE or bytes[p] == SQUOTE or bytes[p] == LPAREN
    ):
        if not had_ws and dest_raw.byte_length() > 0:
            return _LinkSuffix.none()
        var opener = bytes[p]
        var closer = opener
        if opener == LPAREN:
            closer = RPAREN
        p += 1
        var ts = p
        while p < n and bytes[p] != closer:
            if bytes[p] == BSLASH and p + 1 < n:
                p += 1
            p += 1
        if p >= n:
            return _LinkSuffix.none()
        title_raw = sub_string(s, ts, p)
        has_title = True
        p += 1
        p = _skip_link_ws(s, p)
    if p >= n or bytes[p] != RPAREN:
        return _LinkSuffix.none()
    return _LinkSuffix(True, p + 1, dest_raw^, title_raw^, has_title)


def _strip_tags(html: String) -> String:
    """Remove HTML tags, leaving text content (for image alt attributes).

    Operates on inline HTML. Raw inline HTML passes through verbatim, so an
    attribute value *can* contain a raw `>` (e.g. `<span title="a>b">`). The
    tag scan is therefore quote-aware: it only treats a `>` outside a quoted
    attribute as the tag terminator, so such a `>` cannot break out of the
    surrounding `alt="…"` attribute. A nested `<img>` contributes its `alt`
    text rather than vanishing.
    """
    var bytes = html.as_bytes()
    var n = len(bytes)
    var out = String()
    var i = 0
    while i < n:
        var b = bytes[i]
        if b == LT:
            # Scan to the tag's closing `>`, skipping over quoted attribute
            # values so a raw `>` inside an attribute does not end the tag
            # early.
            var j = i + 1
            var in_quote = False
            var quote_ch = UInt8(0)
            while j < n:
                var c = bytes[j]
                if in_quote:
                    if c == quote_ch:
                        in_quote = False
                elif c == QUOTE or c == SQUOTE:
                    in_quote = True
                    quote_ch = c
                elif c == GT:
                    break
                j += 1
            # A nested image keeps its alt text.
            if _match_bytes(bytes, i + 1, "img ") or _match_bytes(
                bytes, i + 1, "img\t"
            ):
                var alt_start = -1
                for k in range(i + 1, j):
                    if _match_bytes(bytes, k, 'alt="'):
                        alt_start = k + 5
                        break
                if alt_start >= 0:
                    var e = alt_start
                    while e < j and bytes[e] != QUOTE:
                        e += 1
                    out += String(
                        StringSlice(unsafe_from_utf8=bytes[alt_start:e])
                    )
            i = j + 1
        else:
            out += byte_char(b)
            i += 1
    return out^


def _match_bytes[
    o: Origin
](bytes: Span[UInt8, o], pos: Int, literal: StaticString) -> Bool:
    var lit = literal.as_bytes()
    if pos + len(lit) > len(bytes):
        return False
    for k in range(len(lit)):
        if bytes[pos + k] != lit[k]:
            return False
    return True


def _emit_range(chunks: List[_Chunk], lo: Int, hi: Int) raises -> String:
    var out = String()
    for k in range(lo, hi):
        if chunks[k].is_delim:
            for t in chunks[k].close_tags:
                if t == 2:
                    out += "</strong>"
                else:
                    out += "</em>"
            for _ in range(chunks[k].count):
                out += byte_char(chunks[k].ch)
            var m = len(chunks[k].open_tags)
            while m > 0:
                m -= 1
                if chunks[k].open_tags[m] == 2:
                    out += "<strong>"
                else:
                    out += "<em>"
        else:
            out += chunks[k].html
    return out^


def _close_bracket(
    s: String,
    i: Int,
    refs: RefMap,
    mut chunks: List[_Chunk],
    mut open_stack: List[Int],
    mut text: String,
) raises -> Int:
    """Handle a `]` at `i`, resolving a link or image against the bracket
    stack. Returns the position past the construct."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    _flush_text(chunks, text)
    if len(open_stack) == 0:
        text += "]"
        return i + 1
    var opener_idx = open_stack.pop()
    if not chunks[opener_idx].active:
        # A `[` opener deactivated by an earlier link: render literally.
        text += "]"
        return i + 1
    var is_image = chunks[opener_idx].is_image
    var label_start = chunks[opener_idx].pos + 1
    if is_image:
        label_start = chunks[opener_idx].pos + 2
    var label = sub_string(s, label_start, i)
    var p = i + 1
    var dest_raw = String()
    var title_raw = String()
    var has_title = False
    var resolved = False
    # Inline link/image: [text](dest "title")
    if p < n and bytes[p] == LPAREN:
        var suffix = _parse_inline_suffix(s, p)
        if suffix.ok:
            dest_raw = suffix.dest.copy()
            title_raw = suffix.title.copy()
            has_title = suffix.has_title
            p = suffix.end
            resolved = True
    # Full or collapsed reference: [text][label] / [text][]
    var followed_by_bracket = False
    if not resolved and p < n and bytes[p] == LBRACKET:
        followed_by_bracket = True
        var q = p + 1
        var ref_closed = False
        while q < n:
            if bytes[q] == BSLASH and q + 1 < n:
                q += 2
                continue
            if bytes[q] == RBRACKET:
                ref_closed = True
                break
            if bytes[q] == LBRACKET:
                break
            q += 1
        if ref_closed:
            var ref_label = sub_string(s, p + 1, q)
            if ref_label.byte_length() == 0:
                ref_label = label.copy()
            var idx = refs.lookup(ref_label)
            if idx >= 0:
                dest_raw = refs.dests[idx].copy()
                title_raw = refs.titles[idx].copy()
                has_title = refs.has_title[idx]
                p = q + 1
                resolved = True
    # Shortcut reference: [label] (only when not immediately followed by an
    # opening bracket, which would have been a full/collapsed reference).
    if not resolved and not followed_by_bracket:
        var idx = refs.lookup(label)
        if idx >= 0:
            dest_raw = refs.dests[idx].copy()
            title_raw = refs.titles[idx].copy()
            has_title = refs.has_title[idx]
            resolved = True
    if not resolved:
        text += "]"
        return i + 1
    # A link or image is formed. Its interior spans the chunks after the
    # opener; process their emphasis before wrapping.
    var content_lo = opener_idx + 1
    var content_hi = len(chunks)
    _process_emphasis(chunks, content_lo, content_hi)
    var href = escape_html(encode_url(resolve_refs(dest_raw)))
    if is_image:
        var alt = _strip_tags(_emit_range(chunks, content_lo, content_hi))
        var html = String('<img src="') + href + '" alt="' + alt + '"'
        if has_title:
            html += ' title="' + escape_html(resolve_refs(title_raw)) + '"'
        html += " />"
        chunks[opener_idx] = _Chunk.text(html^)
        for k in range(content_lo, content_hi):
            chunks[k] = _Chunk.text(String())
        return p
    var open_html = String('<a href="') + href + '"'
    if has_title:
        open_html += ' title="' + escape_html(resolve_refs(title_raw)) + '"'
    open_html += ">"
    chunks[opener_idx] = _Chunk.text(open_html^)
    # Interior delimiters cannot pair with anything outside the link.
    for k in range(content_lo, content_hi):
        if chunks[k].is_delim:
            chunks[k].can_open = False
            chunks[k].can_close = False
    chunks.append(_Chunk.text(String("</a>")))
    # A link cannot appear inside another link's text: deactivate every
    # earlier link opener still on the stack (image openers are exempt).
    for k in range(len(open_stack)):
        if not chunks[open_stack[k]].is_image:
            chunks[open_stack[k]].active = False
    return p


def _tokenize(s: String, refs: RefMap) raises -> List[_Chunk]:
    var bytes = s.as_bytes()
    var n = len(bytes)
    var chunks = List[_Chunk]()
    var open_stack = List[Int]()
    var text = String()
    var i = 0
    while i < n:
        var b = bytes[i]
        if b == BSLASH:
            if i + 1 < n and bytes[i + 1] == NEWLINE:
                _flush_text(chunks, text)
                chunks.append(_Chunk.text(String("<br />\n")))
                i += 2
                while i < n and bytes[i] == SPACE:
                    i += 1
            elif i + 1 < n and is_punct_byte(bytes[i + 1]):
                text += byte_char(bytes[i + 1])
                i += 2
            else:
                text += "\\"
                i += 1
        elif b == NEWLINE:
            var tb = text.as_bytes()
            var k = len(tb)
            while k > 0 and tb[k - 1] == SPACE:
                k -= 1
            var spaces = len(tb) - k
            var trimmed = String(StringSlice(unsafe_from_utf8=tb[0:k]))
            text = trimmed^
            _flush_text(chunks, text)
            if spaces >= 2:
                chunks.append(_Chunk.text(String("<br />\n")))
            else:
                chunks.append(_Chunk.text(String("\n")))
            i += 1
            while i < n and bytes[i] == SPACE:
                i += 1
        elif b == BACKTICK:
            i = _code_span(s, i, chunks, text)
        elif b == STAR or b == UNDERSCORE:
            i = _delimiter_run(s, i, chunks, text)
        elif b == LT:
            var moved = _angle(s, i, chunks, text)
            if moved > i:
                i = moved
            else:
                text += "<"
                i += 1
        elif b == AMP:
            var consumed = match_entity(s, i, text)
            if consumed > i:
                i = consumed
            else:
                text += "&"
                i += 1
        elif b == BANG and i + 1 < n and bytes[i + 1] == LBRACKET:
            _flush_text(chunks, text)
            chunks.append(_Chunk.bopen(i, True))
            open_stack.append(len(chunks) - 1)
            i += 2
        elif b == LBRACKET:
            _flush_text(chunks, text)
            chunks.append(_Chunk.bopen(i, False))
            open_stack.append(len(chunks) - 1)
            i += 1
        elif b == RBRACKET:
            i = _close_bracket(s, i, refs, chunks, open_stack, text)
        else:
            var run = i
            while i < n:
                b = bytes[i]
                if (
                    b == BSLASH
                    or b == NEWLINE
                    or b == BACKTICK
                    or (b == STAR)
                    or b == UNDERSCORE
                    or b == LT
                    or b == AMP
                    or (b == LBRACKET)
                    or b == RBRACKET
                    or b == BANG
                ):
                    break
                i += 1
            if i == run:
                # A special byte (a lone '!') with no handler: consume it
                # literally so the scan always advances.
                text += byte_char(bytes[i])
                i += 1
            else:
                text += sub_string(s, run, i)
    _flush_text(chunks, text)
    return chunks^


def _process_emphasis(mut chunks: List[_Chunk], lo: Int, hi: Int):
    """Match emphasis delimiters in [lo, hi) (with the multiple-of-3 rule)."""
    var closer = lo
    while closer < hi:
        if not (
            chunks[closer].is_delim
            and chunks[closer].can_close
            and chunks[closer].count > 0
        ):
            closer += 1
            continue
        var opener = -1
        var probe = closer - 1
        while probe >= lo:
            if (
                chunks[probe].is_delim
                and chunks[probe].ch == chunks[closer].ch
                and chunks[probe].can_open
                and chunks[probe].count > 0
            ):
                var skip = False
                if chunks[closer].can_open or chunks[probe].can_close:
                    var total = (
                        chunks[probe].orig_count + chunks[closer].orig_count
                    )
                    if total % 3 == 0 and not (
                        chunks[probe].orig_count % 3 == 0
                        and chunks[closer].orig_count % 3 == 0
                    ):
                        skip = True
                if not skip:
                    opener = probe
                    break
            probe -= 1
        if opener == -1:
            if not chunks[closer].can_open:
                chunks[closer].can_close = False
            closer += 1
            continue
        var use = 1
        if chunks[opener].count >= 2 and chunks[closer].count >= 2:
            use = 2
        chunks[opener].count = chunks[opener].count - use
        chunks[closer].count = chunks[closer].count - use
        chunks[opener].open_tags.append(use)
        chunks[closer].close_tags.append(use)
        for k in range(opener + 1, closer):
            if chunks[k].is_delim:
                chunks[k].can_open = False
                chunks[k].can_close = False
        if chunks[closer].count == 0:
            closer += 1


def _emit(chunks: List[_Chunk]) raises -> String:
    return _emit_range(chunks, 0, len(chunks))


def render_inlines(source: String, refs: RefMap) raises -> String:
    """Render span-level markdown content to HTML."""
    # Strip trailing spaces so a would-be hard break at the end of the
    # block renders as nothing.
    var bytes = source.as_bytes()
    var end = len(bytes)
    while end > 0 and (bytes[end - 1] == SPACE or bytes[end - 1] == TAB):
        end -= 1
    var s = sub_string(source, 0, end)
    var chunks = _tokenize(s, refs)
    _process_emphasis(chunks, 0, len(chunks))
    return _emit(chunks)


def render_inlines(source: String) raises -> String:
    """Render span-level markdown with no reference definitions in scope."""
    return render_inlines(source, RefMap.empty())
