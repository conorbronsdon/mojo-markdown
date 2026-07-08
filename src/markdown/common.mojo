"""Byte-level helpers shared by the block parser, inline parser, and renderer.

All scanning operates on UTF-8 bytes. Multi-byte sequences are never split:
helpers either copy whole byte ranges or classify single ASCII bytes, and
any byte >= 0x80 is treated as an ordinary (non-space, non-punctuation)
character, which keeps multi-byte codepoints intact.
"""

comptime AMP = UInt8(0x26)
comptime LT = UInt8(0x3C)
comptime GT = UInt8(0x3E)
comptime QUOTE = UInt8(0x22)
comptime SQUOTE = UInt8(0x27)
comptime BSLASH = UInt8(0x5C)
comptime NEWLINE = UInt8(0x0A)
comptime SPACE = UInt8(0x20)
comptime TAB = UInt8(0x09)
comptime BACKTICK = UInt8(0x60)
comptime TILDE = UInt8(0x7E)
comptime STAR = UInt8(0x2A)
comptime UNDERSCORE = UInt8(0x5F)
comptime LBRACKET = UInt8(0x5B)
comptime RBRACKET = UInt8(0x5D)
comptime LPAREN = UInt8(0x28)
comptime RPAREN = UInt8(0x29)
comptime BANG = UInt8(0x21)
comptime HASH = UInt8(0x23)
comptime DASH = UInt8(0x2D)
comptime PLUS = UInt8(0x2B)
comptime EQUALS = UInt8(0x3D)
comptime SLASH = UInt8(0x2F)
comptime COLON = UInt8(0x3A)
comptime AT = UInt8(0x40)
comptime QUESTION = UInt8(0x3F)
comptime SEMI = UInt8(0x3B)
comptime PERIOD = UInt8(0x2E)


def is_space_byte(b: UInt8) -> Bool:
    return (
        b == 0x20
        or b == 0x09
        or b == 0x0A
        or b == 0x0B
        or b == 0x0C
        or b == 0x0D
    )


def is_punct_byte(b: UInt8) -> Bool:
    return (
        (b >= 0x21 and b <= 0x2F)
        or (b >= 0x3A and b <= 0x40)
        or (b >= 0x5B and b <= 0x60)
        or (b >= 0x7B and b <= 0x7E)
    )


def is_digit_byte(b: UInt8) -> Bool:
    return b >= 0x30 and b <= 0x39


def is_alpha_byte(b: UInt8) -> Bool:
    return (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A)


def is_alnum_byte(b: UInt8) -> Bool:
    return is_alpha_byte(b) or is_digit_byte(b)


def to_lower_byte(b: UInt8) -> UInt8:
    if b >= 0x41 and b <= 0x5A:
        return b + 0x20
    return b


def sub_string(s: String, start: Int, end: Int) -> String:
    """Owned copy of the byte range [start, end) of `s`, clamped to bounds."""
    var bytes = s.as_bytes()
    var a = start
    var b = end
    if a < 0:
        a = 0
    if b > len(bytes):
        b = len(bytes)
    if a >= b:
        return String()
    return String(StringSlice(unsafe_from_utf8=bytes[a:b]))


def byte_char(b: UInt8) -> String:
    """One-byte String for an ASCII byte value."""
    var buf = List[UInt8]()
    buf.append(b)
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


def append_codepoint(mut out: String, cp_in: Int):
    """UTF-8 encode a Unicode scalar value and append it to `out`.

    Out-of-range and surrogate codepoints become U+FFFD so the output is
    always valid UTF-8.
    """
    var cp = cp_in
    if cp <= 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF):
        cp = 0xFFFD
    var buf = List[UInt8]()
    if cp < 0x80:
        buf.append(UInt8(cp))
    elif cp < 0x800:
        buf.append(UInt8(0xC0 | (cp >> 6)))
        buf.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        buf.append(UInt8(0xE0 | (cp >> 12)))
        buf.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        buf.append(UInt8(0xF0 | (cp >> 18)))
        buf.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        buf.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (cp & 0x3F)))
    out += String(StringSlice(unsafe_from_utf8=Span(buf)))


def escape_html(s: String) -> String:
    """Escape & < > " for safe use in HTML text and attribute values."""
    var bytes = s.as_bytes()
    var out = String()
    var run = 0
    var i = 0
    var changed = False
    while i < len(bytes):
        var b = bytes[i]
        if b == AMP or b == LT or b == GT or b == QUOTE:
            if i > run:
                out += String(StringSlice(unsafe_from_utf8=bytes[run:i]))
            if b == AMP:
                out += "&amp;"
            elif b == LT:
                out += "&lt;"
            elif b == GT:
                out += "&gt;"
            else:
                out += "&quot;"
            run = i + 1
            changed = True
        i += 1
    if not changed:
        return s.copy()
    if i > run:
        out += String(StringSlice(unsafe_from_utf8=bytes[run:i]))
    return out^


comptime _HEX_DIGITS: StaticString = "0123456789ABCDEF"


def _href_safe(b: UInt8) -> Bool:
    if is_alnum_byte(b):
        return True
    comptime safe: StaticString = "!#$%&'()*+,-./:;=?@_~"
    var sb = safe.as_bytes()
    for k in range(len(sb)):
        if sb[k] == b:
            return True
    return False


def encode_url(s: String) -> String:
    """Percent-encode URL bytes that cmark treats as unsafe in href/src.

    Existing percent escapes are left alone; `&` survives here and is
    entity-escaped later by `escape_html`.
    """
    var bytes = s.as_bytes()
    var out = String()
    var hex_digits = _HEX_DIGITS.as_bytes()
    var i = 0
    while i < len(bytes):
        var b = bytes[i]
        if _href_safe(b):
            var run = i
            while i < len(bytes) and _href_safe(bytes[i]):
                i += 1
            out += String(StringSlice(unsafe_from_utf8=bytes[run:i]))
            continue
        var buf = List[UInt8]()
        buf.append(UInt8(0x25))
        buf.append(hex_digits[Int(b >> 4)])
        buf.append(hex_digits[Int(b & 0x0F)])
        out += String(StringSlice(unsafe_from_utf8=Span(buf)))
        i += 1
    return out^


def _named_entity_cp(name: String) -> Int:
    """Codepoint for a small set of common named entities, or -1."""
    if name == "amp":
        return 38
    if name == "lt":
        return 60
    if name == "gt":
        return 62
    if name == "quot":
        return 34
    if name == "apos":
        return 39
    if name == "nbsp":
        return 160
    if name == "copy":
        return 169
    if name == "reg":
        return 174
    if name == "deg":
        return 176
    if name == "plusmn":
        return 177
    if name == "middot":
        return 183
    if name == "laquo":
        return 171
    if name == "raquo":
        return 187
    if name == "frac12":
        return 189
    if name == "frac34":
        return 190
    if name == "times":
        return 215
    if name == "divide":
        return 247
    if name == "auml":
        return 228
    if name == "ouml":
        return 246
    if name == "uuml":
        return 252
    if name == "szlig":
        return 223
    if name == "aelig":
        return 230
    if name == "AElig":
        return 198
    if name == "eacute":
        return 233
    if name == "egrave":
        return 232
    if name == "ccedil":
        return 231
    if name == "sect":
        return 167
    if name == "para":
        return 182
    if name == "euro":
        return 8364
    if name == "bull":
        return 8226
    if name == "ndash":
        return 8211
    if name == "mdash":
        return 8212
    if name == "lsquo":
        return 8216
    if name == "rsquo":
        return 8217
    if name == "ldquo":
        return 8220
    if name == "rdquo":
        return 8221
    if name == "hellip":
        return 8230
    if name == "trade":
        return 8482
    if name == "larr":
        return 8592
    if name == "rarr":
        return 8594
    if name == "le":
        return 8804
    if name == "ge":
        return 8805
    if name == "ne":
        return 8800
    return -1


def match_entity(s: String, start: Int, mut out: String) -> Int:
    """Try to decode an HTML entity beginning at byte `start` (a '&').

    On success, append the decoded text to `out` and return the index just
    past the ';'. On failure, return `start` unchanged.
    """
    var bytes = s.as_bytes()
    var n = len(bytes)
    var i = start + 1
    if i >= n:
        return start
    if bytes[i] == HASH:
        i += 1
        var is_hex = False
        if i < n and (bytes[i] == UInt8(0x78) or bytes[i] == UInt8(0x58)):
            is_hex = True
            i += 1
        var digits = 0
        var cp = 0
        while i < n and bytes[i] != SEMI:
            var d = Int(bytes[i])
            if is_hex:
                if d >= 0x30 and d <= 0x39:
                    cp = cp * 16 + (d - 0x30)
                elif d >= 0x61 and d <= 0x66:
                    cp = cp * 16 + (d - 0x61 + 10)
                elif d >= 0x41 and d <= 0x46:
                    cp = cp * 16 + (d - 0x41 + 10)
                else:
                    return start
            else:
                if d >= 0x30 and d <= 0x39:
                    cp = cp * 10 + (d - 0x30)
                else:
                    return start
            digits += 1
            if digits > 7:
                return start
            i += 1
        if i >= n or digits == 0:
            return start
        append_codepoint(out, cp)
        return i + 1
    var name_start = i
    while i < n and is_alnum_byte(bytes[i]) and i - name_start < 32:
        i += 1
    if i >= n or bytes[i] != SEMI or i == name_start:
        return start
    var cp = _named_entity_cp(sub_string(s, name_start, i))
    if cp < 0:
        return start
    append_codepoint(out, cp)
    return i + 1


def _match_at(s: String, pos: Int, literal: StaticString) -> Bool:
    var bytes = s.as_bytes()
    var lit = literal.as_bytes()
    if pos + len(lit) > len(bytes):
        return False
    for k in range(len(lit)):
        if bytes[pos + k] != lit[k]:
            return False
    return True


def scan_html_tag(s: String, start: Int) -> Int:
    """Length of a raw HTML construct starting at `start` ('<'), or 0.

    Recognizes open tags, closing tags, comments (including the short
    `<!-->` and `<!--->` forms), processing instructions, declarations,
    and CDATA sections.
    """
    var bytes = s.as_bytes()
    var n = len(bytes)
    var i = start + 1
    if i >= n:
        return 0
    # Comment: <!-- ... -->  (also permits <!--> and <!--->)
    if (
        i + 2 < n
        and bytes[i] == BANG
        and bytes[i + 1] == DASH
        and (bytes[i + 2] == DASH)
    ):
        var j = i + 1
        while j + 2 < n:
            if (
                bytes[j] == DASH
                and bytes[j + 1] == DASH
                and (bytes[j + 2] == GT)
            ):
                return j + 3 - start
            j += 1
        return 0
    # CDATA: <![CDATA[ ... ]]>
    if _match_at(s, i, "![CDATA["):
        var j = i + 8
        while j + 2 < n:
            if (
                bytes[j] == UInt8(0x5D)
                and bytes[j + 1] == UInt8(0x5D)
                and (bytes[j + 2] == GT)
            ):
                return j + 3 - start
            j += 1
        return 0
    # Declaration: <! followed by a letter, up to >
    if bytes[i] == BANG and i + 1 < n and is_alpha_byte(bytes[i + 1]):
        var j = i + 1
        while j < n:
            if bytes[j] == GT:
                return j + 1 - start
            j += 1
        return 0
    # Processing instruction: <? ... ?>
    if bytes[i] == QUESTION:
        var j = i + 1
        while j + 1 < n:
            if bytes[j] == QUESTION and bytes[j + 1] == GT:
                return j + 2 - start
            j += 1
        return 0
    # Closing tag: </name whitespace* >
    var closing = False
    if bytes[i] == SLASH:
        closing = True
        i += 1
    if i >= n or not is_alpha_byte(bytes[i]):
        return 0
    i += 1
    while i < n and (is_alnum_byte(bytes[i]) or bytes[i] == DASH):
        i += 1
    if closing:
        while i < n and is_space_byte(bytes[i]):
            i += 1
        if i < n and bytes[i] == GT:
            return i + 1 - start
        return 0
    # Open tag: attributes, optional /, then >
    while True:
        var ws = 0
        while i < n and is_space_byte(bytes[i]):
            ws += 1
            i += 1
        if i >= n:
            return 0
        if bytes[i] == GT:
            return i + 1 - start
        if bytes[i] == SLASH:
            i += 1
            if i < n and bytes[i] == GT:
                return i + 1 - start
            return 0
        if ws == 0:
            return 0
        # Attribute name
        var b = bytes[i]
        if not (is_alpha_byte(b) or b == UNDERSCORE or b == COLON):
            return 0
        i += 1
        while i < n:
            b = bytes[i]
            if (
                is_alnum_byte(b)
                or b == UNDERSCORE
                or b == COLON
                or (b == PERIOD)
                or b == DASH
            ):
                i += 1
            else:
                break
        # Optional value
        var save = i
        while i < n and is_space_byte(bytes[i]):
            i += 1
        if i < n and bytes[i] == EQUALS:
            i += 1
            while i < n and is_space_byte(bytes[i]):
                i += 1
            if i >= n:
                return 0
            var q = bytes[i]
            if q == QUOTE or q == SQUOTE:
                i += 1
                while i < n and bytes[i] != q:
                    i += 1
                if i >= n:
                    return 0
                i += 1
            else:
                var vlen = 0
                while i < n:
                    b = bytes[i]
                    if (
                        is_space_byte(b)
                        or b == QUOTE
                        or b == SQUOTE
                        or (b == EQUALS)
                        or b == LT
                        or b == GT
                        or b == BACKTICK
                    ):
                        break
                    i += 1
                    vlen += 1
                if vlen == 0:
                    return 0
        else:
            i = save


def codepoint_before(s: String, pos: Int) -> Int:
    """Unicode codepoint ending just before byte `pos`, or 0x20 at start."""
    var bytes = s.as_bytes()
    if pos <= 0 or pos > len(bytes):
        return 0x20
    var i = pos - 1
    while i > 0 and (bytes[i] & 0xC0) == 0x80:
        i -= 1
    return codepoint_at(s, i)


def codepoint_at(s: String, pos: Int) -> Int:
    """Unicode codepoint starting at byte `pos`, or 0x20 past the end."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    if pos < 0 or pos >= n:
        return 0x20
    var b = Int(bytes[pos])
    if b < 0x80:
        return b
    var seq: Int
    var cp: Int
    if b >= 0xC2 and b <= 0xDF:
        seq = 2
        cp = b & 0x1F
    elif b >= 0xE0 and b <= 0xEF:
        seq = 3
        cp = b & 0x0F
    elif b >= 0xF0 and b <= 0xF4:
        seq = 4
        cp = b & 0x07
    else:
        return 0xFFFD
    if pos + seq > n:
        return 0xFFFD
    for k in range(1, seq):
        var c = Int(bytes[pos + k])
        if c < 0x80 or c > 0xBF:
            return 0xFFFD
        cp = (cp << 6) | (c & 0x3F)
    return cp


def is_uni_space(cp: Int) -> Bool:
    """Unicode whitespace as used by the emphasis flanking rules."""
    if cp == 0x20 or cp == 0x09 or cp == 0x0A or cp == 0x0B or cp == 0x0C:
        return True
    if cp == 0x0D or cp == 0xA0 or cp == 0x1680:
        return True
    if cp >= 0x2000 and cp <= 0x200A:
        return True
    return (
        cp == 0x2028
        or cp == 0x2029
        or cp == 0x202F
        or cp == 0x205F
        or (cp == 0x3000)
    )


def is_uni_punct(cp: Int) -> Bool:
    """Approximate Unicode punctuation/symbols for flanking rules.

    Exact per spec for ASCII; for non-ASCII this covers the Latin-1
    punctuation range, general punctuation, and currency symbols, which
    handles the common cases without full category tables.
    """
    if cp < 0x80:
        return is_punct_byte(UInt8(cp))
    if cp >= 0xA1 and cp <= 0xBF:
        return True
    if cp == 0xD7 or cp == 0xF7:
        return True
    if cp >= 0x2010 and cp <= 0x2027:
        return True
    if cp >= 0x2030 and cp <= 0x205E:
        return True
    return cp >= 0x20A0 and cp <= 0x20CF


def normalize_label(s: String) -> String:
    """Normalize a link label: trim, collapse whitespace, ASCII-lowercase."""
    var bytes = s.as_bytes()
    var i = 0
    var end = len(bytes)
    while i < end and is_space_byte(bytes[i]):
        i += 1
    while end > i and is_space_byte(bytes[end - 1]):
        end -= 1
    var out = String()
    var in_ws = False
    while i < end:
        var b = bytes[i]
        if is_space_byte(b):
            in_ws = True
        else:
            if in_ws:
                out += " "
            in_ws = False
            out += byte_char(to_lower_byte(b))
        i += 1
    return out^


@fieldwise_init
struct RefMap(Copyable, Movable):
    """Link reference definitions collected during block parsing.

    Destinations and titles are stored raw; escapes and entities are
    resolved when a reference is rendered.
    """

    var names: List[String]
    var dests: List[String]
    var titles: List[String]
    var has_title: List[Bool]

    @staticmethod
    def empty() -> RefMap:
        return RefMap(
            List[String](), List[String](), List[String](), List[Bool]()
        )

    def lookup(self, label: String) -> Int:
        var key = normalize_label(label)
        for k in range(len(self.names)):
            if self.names[k] == key:
                return k
        return -1

    def add(
        mut self,
        label: String,
        var dest: String,
        var title: String,
        has_title: Bool,
    ):
        var key = normalize_label(label)
        for k in range(len(self.names)):
            if self.names[k] == key:
                return
        self.names.append(key^)
        self.dests.append(dest^)
        self.titles.append(title^)
        self.has_title.append(has_title)


def resolve_refs(s: String) -> String:
    """Process backslash escapes and entity references in a raw span.

    Used for link destinations, link titles, and code fence info strings,
    where escapes are resolved before HTML/URL escaping.
    """
    var bytes = s.as_bytes()
    var n = len(bytes)
    var out = String()
    var i = 0
    while i < n:
        var b = bytes[i]
        if b == BSLASH and i + 1 < n and is_punct_byte(bytes[i + 1]):
            out += byte_char(bytes[i + 1])
            i += 2
            continue
        if b == AMP:
            var consumed = match_entity(s, i, out)
            if consumed > i:
                i = consumed
                continue
        var run = i
        while i < n and bytes[i] != BSLASH and bytes[i] != AMP:
            i += 1
        if i == run:
            out += byte_char(bytes[i])
            i += 1
        else:
            out += String(StringSlice(unsafe_from_utf8=bytes[run:i]))
    return out^
