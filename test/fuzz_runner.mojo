"""Fuzz target: render argv[1] file content to HTML.

Reads the file named by argv[1], runs it through `render_html`, and prints
the output length. Raising is acceptable; crashing or hanging is not. Feed
it the spec corpus and pathological inputs (deeply nested brackets, long
delimiter runs, deep blockquotes) to check robustness.
"""

from std.sys import argv

from markdown import render_html


def main():
    try:
        var source = open(String(argv()[1]), "r").read()
        var html = render_html(source)
        print("input bytes:", source.byte_length())
        print("output bytes:", html.byte_length())
    except e:
        print("raised:", e)
