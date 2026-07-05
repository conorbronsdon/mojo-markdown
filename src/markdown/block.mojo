"""Block parser: builds a block-level AST from markdown source.

The tree is stored as an arena (`BlockTree.nodes`); each `Block` holds the
indices of its children. Container blocks (blockquotes, lists, list items)
are parsed recursively: the container's marker prefix is stripped from its
lines and the remainder is fed back through the same line dispatcher.
"""

from markdown.common import (
    BACKTICK,
    BANG,
    BSLASH,
    COLON,
    DASH,
    EQUALS,
    GT,
    HASH,
    LBRACKET,
    LPAREN,
    LT,
    NEWLINE,
    PERIOD,
    PLUS,
    QUESTION,
    QUOTE,
    RBRACKET,
    RPAREN,
    SLASH,
    SPACE,
    SQUOTE,
    STAR,
    TAB,
    TILDE,
    UNDERSCORE,
    RefMap,
    append_codepoint,
    byte_char,
    is_alpha_byte,
    is_alnum_byte,
    is_digit_byte,
    is_space_byte,
    scan_html_tag,
    sub_string,
    to_lower_byte,
)

# Maximum container (blockquote / list item) nesting depth. Beyond this,
# container markers are treated as ordinary paragraph text so that
# pathological input (e.g. thousands of leading `>`) cannot overflow the
# stack via recursive descent. Deep but non-pathological documents are
# unaffected.
comptime _MAX_NEST = 256

comptime B_DOCUMENT = 0
comptime B_PARAGRAPH = 1
comptime B_HEADING = 2
comptime B_CODE = 3
comptime B_HTML = 4
comptime B_QUOTE = 5
comptime B_LIST = 6
comptime B_ITEM = 7
comptime B_BREAK = 8

comptime _BLOCK_TAGS: StaticString = (
    " address article aside base basefont blockquote body caption center"
    " col colgroup dd details dialog dir div dl dt fieldset figcaption"
    " figure footer form frame frameset h1 h2 h3 h4 h5 h6 head header hr"
    " html iframe legend li link main menu menuitem nav noframes ol"
    " optgroup option p param search section summary table tbody td tfoot"
    " th thead title tr track ul "
)


@fieldwise_init
struct Block(Copyable, Movable):
    """One node in the block tree.

    `text` holds paragraph/heading source (inlines unparsed), literal code
    content, or raw HTML. `info` is the fence info string. `level` is the
    heading level or the ordered-list start number.
    """

    var kind: Int
    var text: String
    var info: String
    var level: Int
    var ordered: Bool
    var tight: Bool
    var children: List[Int]


@fieldwise_init
struct BlockTree(Copyable, Movable):
    var nodes: List[Block]
    var root: Int
    var refs: RefMap


@fieldwise_init
struct _ListMarker(Copyable, Movable):
    var found: Bool
    var ordered: Bool
    var start: Int
    var delim: UInt8
    var content_col: Int
    var blank_after: Bool

    @staticmethod
    def none() -> _ListMarker:
        return _ListMarker(False, False, 0, UInt8(0), 0, False)


@fieldwise_init
struct _Fence(Copyable, Movable):
    var found: Bool
    var ch: UInt8
    var length: Int
    var indent: Int
    var info: String

    @staticmethod
    def none() -> _Fence:
        return _Fence(False, UInt8(0), 0, 0, String())


def _preprocess(source: String) -> List[String]:
    """Split into lines; expand tabs to 4-column stops; replace NUL."""
    var bytes = source.as_bytes()
    var out = List[String]()
    var buf = List[UInt8]()
    var col = 0
    var i = 0
    var n = len(bytes)
    while i < n:
        var b = bytes[i]
        if b == NEWLINE:
            out.append(String(StringSlice(unsafe_from_utf8=Span(buf))))
            buf.clear()
            col = 0
            i += 1
        elif b == UInt8(0x0D):
            out.append(String(StringSlice(unsafe_from_utf8=Span(buf))))
            buf.clear()
            col = 0
            if i + 1 < n and bytes[i + 1] == NEWLINE:
                i += 2
            else:
                i += 1
        elif b == TAB:
            var pad = 4 - (col % 4)
            for _ in range(pad):
                buf.append(SPACE)
            col += pad
            i += 1
        elif b == UInt8(0):
            buf.append(UInt8(0xEF))
            buf.append(UInt8(0xBF))
            buf.append(UInt8(0xBD))
            col += 1
            i += 1
        else:
            buf.append(b)
            col += 1
            i += 1
    if len(buf) > 0:
        out.append(String(StringSlice(unsafe_from_utf8=Span(buf))))
    return out^


def _indent_of(line: String) -> Int:
    var bytes = line.as_bytes()
    var i = 0
    while i < len(bytes) and bytes[i] == SPACE:
        i += 1
    return i


def _is_blank(line: String) -> Bool:
    var bytes = line.as_bytes()
    for k in range(len(bytes)):
        if bytes[k] != SPACE:
            return False
    return True


def _ltrim(line: String) -> String:
    return sub_string(line, _indent_of(line), line.byte_length())


def _atx_level(line: String) -> Int:
    var bytes = line.as_bytes()
    var i = _indent_of(line)
    if i > 3:
        return 0
    var level = 0
    while i < len(bytes) and bytes[i] == HASH:
        level += 1
        i += 1
    if level == 0 or level > 6:
        return 0
    if i < len(bytes) and bytes[i] != SPACE:
        return 0
    return level


def _atx_content(line: String) -> String:
    var bytes = line.as_bytes()
    var i = _indent_of(line)
    while i < len(bytes) and bytes[i] == HASH:
        i += 1
    while i < len(bytes) and bytes[i] == SPACE:
        i += 1
    var end = len(bytes)
    while end > i and bytes[end - 1] == SPACE:
        end -= 1
    # Optional closing hash run, which must follow a space (or be the
    # entire remaining content).
    var h = end
    while h > i and bytes[h - 1] == HASH:
        h -= 1
    if h < end and (h == i or bytes[h - 1] == SPACE):
        end = h
        while end > i and bytes[end - 1] == SPACE:
            end -= 1
    return sub_string(line, i, end)


def _is_thematic(line: String) -> Bool:
    var bytes = line.as_bytes()
    var i = _indent_of(line)
    if i > 3 or i >= len(bytes):
        return False
    var ch = bytes[i]
    if ch != DASH and ch != STAR and ch != UNDERSCORE:
        return False
    var count = 0
    while i < len(bytes):
        var b = bytes[i]
        if b == ch:
            count += 1
        elif b != SPACE:
            return False
        i += 1
    return count >= 3


def _setext_level(line: String) -> Int:
    var bytes = line.as_bytes()
    var i = _indent_of(line)
    if i > 3 or i >= len(bytes):
        return 0
    var ch = bytes[i]
    if ch != EQUALS and ch != DASH:
        return 0
    while i < len(bytes) and bytes[i] == ch:
        i += 1
    while i < len(bytes) and bytes[i] == SPACE:
        i += 1
    if i != len(bytes):
        return 0
    if ch == EQUALS:
        return 1
    return 2


def _quote_prefix(line: String) -> Int:
    """Bytes consumed by an opening `>` marker plus one space, or -1."""
    var bytes = line.as_bytes()
    var i = _indent_of(line)
    if i > 3 or i >= len(bytes) or bytes[i] != GT:
        return -1
    i += 1
    if i < len(bytes) and bytes[i] == SPACE:
        i += 1
    return i


def _open_fence(line: String) -> _Fence:
    var bytes = line.as_bytes()
    var indent = _indent_of(line)
    if indent > 3 or indent >= len(bytes):
        return _Fence.none()
    var ch = bytes[indent]
    if ch != BACKTICK and ch != TILDE:
        return _Fence.none()
    var i = indent
    var length = 0
    while i < len(bytes) and bytes[i] == ch:
        length += 1
        i += 1
    if length < 3:
        return _Fence.none()
    var info_start = i
    while i < len(bytes):
        if ch == BACKTICK and bytes[i] == BACKTICK:
            return _Fence.none()
        i += 1
    var info = sub_string(line, info_start, len(bytes))
    # Trim the info string.
    var ib = info.as_bytes()
    var a = 0
    var b = len(ib)
    while a < b and ib[a] == SPACE:
        a += 1
    while b > a and ib[b - 1] == SPACE:
        b -= 1
    return _Fence(True, ch, length, indent, sub_string(info, a, b))


def _is_close_fence(line: String, ch: UInt8, length: Int) -> Bool:
    var bytes = line.as_bytes()
    var i = _indent_of(line)
    if i > 3:
        return False
    var run = 0
    while i < len(bytes) and bytes[i] == ch:
        run += 1
        i += 1
    if run < length:
        return False
    while i < len(bytes):
        if bytes[i] != SPACE:
            return False
        i += 1
    return True


def _list_marker(line: String) -> _ListMarker:
    var bytes = line.as_bytes()
    var indent = _indent_of(line)
    if indent > 3 or indent >= len(bytes):
        return _ListMarker.none()
    var i = indent
    var ordered = False
    var start = 0
    var delim: UInt8
    var b = bytes[i]
    if b == DASH or b == STAR or b == PLUS:
        delim = b
        i += 1
    elif is_digit_byte(b):
        ordered = True
        var digits = 0
        while i < len(bytes) and is_digit_byte(bytes[i]):
            start = start * 10 + (Int(bytes[i]) - 0x30)
            digits += 1
            i += 1
        if digits > 9 or i >= len(bytes):
            return _ListMarker.none()
        if bytes[i] != PERIOD and bytes[i] != RPAREN:
            return _ListMarker.none()
        delim = bytes[i]
        i += 1
    else:
        return _ListMarker.none()
    if i < len(bytes) and bytes[i] != SPACE:
        return _ListMarker.none()
    var spaces = 0
    while i + spaces < len(bytes) and bytes[i + spaces] == SPACE:
        spaces += 1
    var blank_after = i + spaces >= len(bytes)
    var content_col: Int
    if blank_after or spaces >= 5:
        content_col = i + 1
    else:
        content_col = i + spaces
    return _ListMarker(True, ordered, start, delim, content_col, blank_after)


def _html_block_type(line: String) -> Int:
    var bytes = line.as_bytes()
    var i = _indent_of(line)
    if i > 3 or i >= len(bytes) or bytes[i] != LT:
        return 0
    var p = i + 1
    var n = len(bytes)
    if p < n and bytes[p] == BANG:
        if p + 2 < n and bytes[p + 1] == DASH and bytes[p + 2] == DASH:
            return 2
        if _line_match(line, p, "![CDATA["):
            return 5
        if p + 1 < n and is_alpha_byte(bytes[p + 1]):
            return 4
        return 0
    if p < n and bytes[p] == QUESTION:
        return 3
    var closing = False
    if p < n and bytes[p] == SLASH:
        closing = True
        p += 1
    if p >= n or not is_alpha_byte(bytes[p]):
        return 0
    var name = String()
    while p < n and (is_alnum_byte(bytes[p]) or bytes[p] == DASH):
        name += byte_char(to_lower_byte(bytes[p]))
        p += 1
    var terminated = p >= n or bytes[p] == SPACE or bytes[p] == GT
    if not terminated and bytes[p] == SLASH and p + 1 < n and (
        bytes[p + 1] == GT
    ):
        terminated = True
    if not terminated:
        return 0
    if not closing and (
        name == "script" or name == "pre" or name == "style"
        or name == "textarea"
    ):
        return 1
    if String(_BLOCK_TAGS).find(" " + name + " ") >= 0:
        return 6
    # Type 7: a complete tag, alone on its line (cannot interrupt a
    # paragraph — callers treat 7 specially).
    if name == "script" or name == "pre" or name == "style" or (
        name == "textarea"
    ):
        return 0
    var tag_len = scan_html_tag(line, i)
    if tag_len > 0:
        var rest = i + tag_len
        while rest < n and bytes[rest] == SPACE:
            rest += 1
        if rest >= n:
            return 7
    return 0


def _line_match(line: String, pos: Int, literal: StaticString) -> Bool:
    var bytes = line.as_bytes()
    var lit = literal.as_bytes()
    if pos + len(lit) > len(bytes):
        return False
    for k in range(len(lit)):
        if bytes[pos + k] != lit[k]:
            return False
    return True


def _contains_lower(line: String, needle: String) -> Bool:
    """Case-insensitive substring search (ASCII folding)."""
    var hay = line.as_bytes()
    var nee = needle.as_bytes()
    if len(nee) == 0 or len(nee) > len(hay):
        return False
    for i in range(len(hay) - len(nee) + 1):
        var ok = True
        for k in range(len(nee)):
            if to_lower_byte(hay[i + k]) != nee[k]:
                ok = False
                break
        if ok:
            return True
    return False


def _starts_construct(line: String) -> Bool:
    """Whether a line begins a non-paragraph leaf/container block.

    Used to decide when lazy continuation stops inside blockquotes and
    list items.
    """
    if _atx_level(line) > 0:
        return True
    if _open_fence(line).found:
        return True
    if _is_thematic(line):
        return True
    if _quote_prefix(line) >= 0:
        return True
    var m = _list_marker(line)
    if m.found and not m.blank_after:
        return True
    var html_type = _html_block_type(line)
    if html_type > 0 and html_type != 7:
        return True
    return False


def _interrupts_paragraph(line: String) -> Bool:
    if _is_blank(line):
        return True
    if _indent_of(line) >= 4:
        return False
    if _atx_level(line) > 0:
        return True
    if _open_fence(line).found:
        return True
    if _is_thematic(line):
        return True
    if _quote_prefix(line) >= 0:
        return True
    var html_type = _html_block_type(line)
    if html_type > 0 and html_type != 7:
        return True
    var m = _list_marker(line)
    if m.found and not m.blank_after and ((not m.ordered) or m.start == 1):
        return True
    return False


def _parse_defs(mut refs: RefMap, content: String) -> String:
    """Extract leading link reference definitions from paragraph content.

    Returns the remaining paragraph text (empty if the whole paragraph was
    definitions). Recognizes `[label]: dest "title"` with the title
    optionally on the following line.
    """
    var bytes = content.as_bytes()
    var n = len(bytes)
    var pos = 0
    while pos < n and bytes[pos] == LBRACKET:
        var p = pos + 1
        var label_start = p
        var closed = False
        while p < n:
            var b = bytes[p]
            if b == BSLASH and p + 1 < n:
                p += 2
                continue
            if b == RBRACKET:
                closed = True
                break
            if b == LBRACKET:
                break
            p += 1
        if not closed or p - label_start > 999:
            break
        var label = sub_string(content, label_start, p)
        var has_content = False
        var lb = label.as_bytes()
        for k in range(len(lb)):
            if not is_space_byte(lb[k]):
                has_content = True
                break
        if not has_content:
            break
        p += 1
        if p >= n or bytes[p] != COLON:
            break
        p += 1
        # Whitespace before the destination: at most one newline.
        var newlines = 0
        while p < n and (bytes[p] == SPACE or bytes[p] == NEWLINE):
            if bytes[p] == NEWLINE:
                newlines += 1
            p += 1
        if newlines > 1 or p >= n:
            break
        # Destination.
        var dest: String
        if bytes[p] == LT:
            p += 1
            var ds = p
            var ok = True
            while p < n and bytes[p] != GT:
                if bytes[p] == NEWLINE or bytes[p] == LT:
                    ok = False
                    break
                if bytes[p] == BSLASH and p + 1 < n:
                    p += 1
                p += 1
            if not ok or p >= n:
                break
            dest = sub_string(content, ds, p)
            p += 1
        else:
            var ds = p
            while p < n and not is_space_byte(bytes[p]):
                if bytes[p] == BSLASH and p + 1 < n:
                    p += 1
                p += 1
            if p == ds:
                break
            dest = sub_string(content, ds, p)
        # Rest of the destination line.
        var q = p
        while q < n and bytes[q] == SPACE:
            q += 1
        var clean_line = q >= n or bytes[q] == NEWLINE
        # Optional title, possibly on the next line; it must be separated
        # from the destination by whitespace.
        var t = q
        var had_ws = q > p
        if t < n and bytes[t] == NEWLINE:
            t += 1
            had_ws = True
            while t < n and bytes[t] == SPACE:
                t += 1
        var got_title = False
        var title = String()
        var after_title = 0
        if had_ws and t < n and (
            bytes[t] == QUOTE or bytes[t] == SQUOTE or bytes[t] == LPAREN
        ):
            var closer = bytes[t]
            if closer == LPAREN:
                closer = RPAREN
            var u = t + 1
            var ts = u
            var title_closed = False
            while u < n:
                if bytes[u] == BSLASH and u + 1 < n:
                    u += 2
                    continue
                if bytes[u] == closer:
                    title_closed = True
                    break
                u += 1
            if title_closed:
                var v = u + 1
                while v < n and bytes[v] == SPACE:
                    v += 1
                if v >= n or bytes[v] == NEWLINE:
                    got_title = True
                    title = sub_string(content, ts, u)
                    after_title = v
                    if v < n:
                        after_title = v + 1
        if got_title:
            refs.add(label, dest^, title^, True)
            pos = after_title
            continue
        if clean_line:
            refs.add(label, dest^, String(), False)
            pos = q
            if pos < n:
                pos += 1
            continue
        break
    return sub_string(content, pos, n)


struct _Parser(Copyable, Movable):
    var nodes: List[Block]
    var refs: RefMap

    def __init__(out self):
        self.nodes = List[Block]()
        self.refs = RefMap.empty()

    def _finish(deinit self, root: Int) -> BlockTree:
        return BlockTree(self.nodes^, root, self.refs^)

    def _new_node(mut self, kind: Int) -> Int:
        self.nodes.append(
            Block(kind, String(), String(), 0, False, True, List[Int]())
        )
        return len(self.nodes) - 1

    def _flush_para(mut self, mut para: List[String], parent: Int):
        if len(para) == 0:
            return
        var content = String()
        for k in range(len(para)):
            if k > 0:
                content += "\n"
            content += _ltrim(para[k])
        if content.byte_length() > 0 and content.as_bytes()[0] == LBRACKET:
            content = _parse_defs(self.refs, content)
        para.clear()
        if content.byte_length() == 0:
            return
        var idx = self._new_node(B_PARAGRAPH)
        self.nodes[idx].text = content^
        self.nodes[parent].children.append(idx)

    def _parse_into(
        mut self,
        lines: List[String],
        parent: Int,
        mut blank_between: Bool,
        depth: Int,
    ) raises:
        var para = List[String]()
        var pending_gap = False
        var i = 0
        while i < len(lines):
            if len(para) > 0:
                var setext = _setext_level(lines[i])
                if setext > 0:
                    var content = String()
                    for k in range(len(para)):
                        if k > 0:
                            content += "\n"
                        content += _ltrim(para[k])
                    if content.byte_length() > 0 and (
                        content.as_bytes()[0] == LBRACKET
                    ):
                        content = _parse_defs(self.refs, content)
                    para.clear()
                    if content.byte_length() == 0:
                        # The paragraph was only definitions; the would-be
                        # underline stands alone.
                        if _is_thematic(lines[i]):
                            var idx = self._new_node(B_BREAK)
                            self.nodes[parent].children.append(idx)
                        else:
                            para.append(lines[i].copy())
                        i += 1
                        continue
                    var idx = self._new_node(B_HEADING)
                    self.nodes[idx].text = content^
                    self.nodes[idx].level = setext
                    self.nodes[parent].children.append(idx)
                    i += 1
                    continue
                if not _interrupts_paragraph(lines[i]):
                    para.append(lines[i].copy())
                    i += 1
                    continue
                self._flush_para(para, parent)
            if _is_blank(lines[i]):
                if len(self.nodes[parent].children) > 0:
                    pending_gap = True
                i += 1
                continue
            if pending_gap:
                blank_between = True
                pending_gap = False
            var indent = _indent_of(lines[i])
            if indent >= 4:
                i = self._parse_indented_code(lines, i, parent)
                continue
            var fence = _open_fence(lines[i])
            if fence.found:
                i = self._parse_fenced_code(lines, i, parent, fence)
                continue
            var atx = _atx_level(lines[i])
            if atx > 0:
                var idx = self._new_node(B_HEADING)
                self.nodes[idx].level = atx
                self.nodes[idx].text = _atx_content(lines[i])
                self.nodes[parent].children.append(idx)
                i += 1
                continue
            if _is_thematic(lines[i]):
                var idx = self._new_node(B_BREAK)
                self.nodes[parent].children.append(idx)
                i += 1
                continue
            var html_type = _html_block_type(lines[i])
            if html_type > 0:
                i = self._parse_html_block(lines, i, parent, html_type)
                continue
            if _quote_prefix(lines[i]) >= 0 and depth < _MAX_NEST:
                i = self._parse_blockquote(lines, i, parent, depth)
                continue
            var marker = _list_marker(lines[i])
            if marker.found and depth < _MAX_NEST:
                var list_gap = False
                i = self._parse_list(lines, i, parent, marker, list_gap, depth)
                if list_gap and i < len(lines):
                    pending_gap = True
                continue
            para.append(lines[i].copy())
            i += 1
        self._flush_para(para, parent)

    def _parse_indented_code(
        mut self, lines: List[String], start: Int, parent: Int
    ) -> Int:
        var content_lines = List[String]()
        var i = start
        while i < len(lines):
            if _is_blank(lines[i]):
                content_lines.append(
                    sub_string(lines[i], 4, lines[i].byte_length())
                )
                i += 1
                continue
            if _indent_of(lines[i]) >= 4:
                content_lines.append(
                    sub_string(lines[i], 4, lines[i].byte_length())
                )
                i += 1
                continue
            break
        var last = len(content_lines) - 1
        while last >= 0 and _is_blank(content_lines[last]):
            last -= 1
        var text = String()
        for k in range(last + 1):
            text += content_lines[k]
            text += "\n"
        var idx = self._new_node(B_CODE)
        self.nodes[idx].text = text^
        self.nodes[parent].children.append(idx)
        # Only consume through the last code line; trailing blanks return
        # to the dispatcher.
        return start + last + 1

    def _parse_fenced_code(
        mut self, lines: List[String], start: Int, parent: Int, fence: _Fence
    ) -> Int:
        var i = start + 1
        var text = String()
        while i < len(lines):
            if _is_close_fence(lines[i], fence.ch, fence.length):
                i += 1
                break
            var ind = _indent_of(lines[i])
            var strip = fence.indent
            if ind < strip:
                strip = ind
            text += sub_string(lines[i], strip, lines[i].byte_length())
            text += "\n"
            i += 1
        var idx = self._new_node(B_CODE)
        self.nodes[idx].text = text^
        self.nodes[idx].info = fence.info.copy()
        self.nodes[parent].children.append(idx)
        return i

    def _parse_html_block(
        mut self, lines: List[String], start: Int, parent: Int, html_type: Int
    ) -> Int:
        var i = start
        var text = String()
        while i < len(lines):
            if html_type == 6 or html_type == 7:
                if _is_blank(lines[i]):
                    break
                text += lines[i]
                text += "\n"
                i += 1
                continue
            text += lines[i]
            text += "\n"
            var done = False
            if html_type == 1:
                done = (
                    _contains_lower(lines[i], String("</script>"))
                    or _contains_lower(lines[i], String("</pre>"))
                    or _contains_lower(lines[i], String("</style>"))
                    or _contains_lower(lines[i], String("</textarea>"))
                )
            elif html_type == 2:
                done = lines[i].find("-->") >= 0
            elif html_type == 3:
                done = lines[i].find("?>") >= 0
            elif html_type == 4:
                done = lines[i].find(">") >= 0
            elif html_type == 5:
                done = lines[i].find("]]>") >= 0
            i += 1
            if done:
                break
        var idx = self._new_node(B_HTML)
        self.nodes[idx].text = text^
        self.nodes[parent].children.append(idx)
        return i

    def _parse_blockquote(
        mut self, lines: List[String], start: Int, parent: Int, depth: Int
    ) raises -> Int:
        var inner = List[String]()
        var i = start
        var in_fence = False
        var fence_ch = UInt8(0)
        var fence_len = 0
        while i < len(lines):
            var consumed = _quote_prefix(lines[i])
            if consumed >= 0:
                var stripped = sub_string(
                    lines[i], consumed, lines[i].byte_length()
                )
                if in_fence:
                    if _is_close_fence(stripped, fence_ch, fence_len):
                        in_fence = False
                else:
                    var f = _open_fence(stripped)
                    if f.found:
                        in_fence = True
                        fence_ch = f.ch
                        fence_len = f.length
                inner.append(stripped^)
                i += 1
                continue
            if _is_blank(lines[i]):
                break
            # Lazy continuation: only valid while a paragraph is open,
            # which the last quoted line must plausibly be part of.
            if in_fence or len(inner) == 0:
                break
            var last = len(inner) - 1
            if _is_blank(inner[last]) or _indent_of(inner[last]) >= 4:
                break
            if _atx_level(inner[last]) > 0 or _is_thematic(inner[last]):
                break
            var last_html = _html_block_type(inner[last])
            if last_html > 0 and last_html != 7:
                break
            if _starts_construct(lines[i]):
                break
            inner.append(lines[i].copy())
            i += 1
        var idx = self._new_node(B_QUOTE)
        self.nodes[parent].children.append(idx)
        var unused_gap = False
        self._parse_into(inner, idx, unused_gap, depth + 1)
        return i

    def _parse_list(
        mut self,
        lines: List[String],
        start: Int,
        parent: Int,
        first: _ListMarker,
        mut trailing_gap: Bool,
        depth: Int,
    ) raises -> Int:
        var list_idx = self._new_node(B_LIST)
        self.nodes[list_idx].ordered = first.ordered
        self.nodes[list_idx].level = first.start
        self.nodes[parent].children.append(list_idx)
        var bullet = first.delim
        var ordered = first.ordered
        var loose = False
        var blank_between = False
        var i = start
        while i < len(lines):
            if _is_blank(lines[i]) or _is_thematic(lines[i]):
                break
            var m = _list_marker(lines[i])
            if not m.found or m.ordered != ordered or m.delim != bullet:
                break
            if blank_between:
                loose = True
            blank_between = False
            var item_lines = List[String]()
            var has_content = False
            if lines[i].byte_length() > m.content_col:
                item_lines.append(
                    sub_string(lines[i], m.content_col, lines[i].byte_length())
                )
                has_content = not _is_blank(item_lines[0])
            else:
                item_lines.append(String())
            i += 1
            var blanks_pending = 0
            while i < len(lines):
                if _is_blank(lines[i]):
                    blanks_pending += 1
                    i += 1
                    continue
                var ind = _indent_of(lines[i])
                if ind >= m.content_col:
                    # An item may begin with at most one blank line.
                    if blanks_pending > 0 and not has_content:
                        break
                    if blanks_pending > 0:
                        for _ in range(blanks_pending):
                            item_lines.append(String())
                        blanks_pending = 0
                    item_lines.append(
                        sub_string(
                            lines[i], m.content_col, lines[i].byte_length()
                        )
                    )
                    has_content = True
                    i += 1
                    continue
                if blanks_pending > 0:
                    blank_between = True
                    break
                var m2 = _list_marker(lines[i])
                if m2.found:
                    break
                if _starts_construct(lines[i]):
                    break
                if len(item_lines) > 0 and not _is_blank(
                    item_lines[len(item_lines) - 1]
                ):
                    item_lines.append(_ltrim(lines[i]))
                    i += 1
                    continue
                break
            if blanks_pending > 0:
                blank_between = True
            var last = len(item_lines) - 1
            while last >= 0 and _is_blank(item_lines[last]):
                _ = item_lines.pop()
                last -= 1
            var item_idx = self._new_node(B_ITEM)
            self.nodes[list_idx].children.append(item_idx)
            var item_gap = False
            self._parse_into(item_lines, item_idx, item_gap, depth + 1)
            if item_gap:
                loose = True
        self.nodes[list_idx].tight = not loose
        trailing_gap = blank_between
        return i


def parse_blocks(source: String) raises -> BlockTree:
    """Parse markdown source into a block tree rooted at a document node."""
    var lines = _preprocess(source)
    var parser = _Parser()
    var root = parser._new_node(B_DOCUMENT)
    var unused_gap = False
    parser._parse_into(lines, root, unused_gap, 0)
    return parser^._finish(root)
