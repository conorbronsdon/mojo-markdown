"""CommonMark 0.31.2 conformance scoreboard.

Runs every example from the official spec test corpus and reports
per-section and total pass counts. This is a scoreboard, not a gate: it
always exits successfully, whatever the score.

Corpus format (test/data/spec_cases.txt): records separated by \\x1e,
fields within a record separated by \\x1f, in the order
section, example number, markdown, expected html.
"""

from std.sys import argv

from markdown import render_html


def main() raises:
    var detail_section = String()
    if len(argv()) > 1:
        detail_section = String(argv()[1])
    var raw = open("test/data/spec_cases.txt", "r").read()
    var records = raw.split("\x1e")
    var section_names = List[String]()
    var section_pass = List[Int]()
    var section_total = List[Int]()
    var total_pass = 0
    var total = 0
    var failed_examples = List[Int]()
    for r in range(len(records)):
        var fields = records[r].split("\x1f")
        if len(fields) != 4:
            continue
        var section = String(fields[0])
        var example = Int(String(fields[1]))
        var md = String(fields[2])
        var expected = String(fields[3])
        var ok = False
        var got: String
        try:
            got = render_html(md)
            ok = got == expected
        except e:
            got = String("<exception: ") + String(e) + ">"
        if (not ok) and section == detail_section:
            print("=== example " + String(example))
            print("--- markdown:")
            print(md)
            print("--- expected:")
            print(expected)
            print("--- got:")
            print(got)
        var sec_idx = -1
        for k in range(len(section_names)):
            if section_names[k] == section:
                sec_idx = k
                break
        if sec_idx == -1:
            section_names.append(section.copy())
            section_pass.append(0)
            section_total.append(0)
            sec_idx = len(section_names) - 1
        section_total[sec_idx] = section_total[sec_idx] + 1
        total += 1
        if ok:
            section_pass[sec_idx] = section_pass[sec_idx] + 1
            total_pass += 1
        else:
            failed_examples.append(example)
    print("CommonMark 0.31.2 conformance")
    print("-----------------------------")
    for k in range(len(section_names)):
        print(
            section_names[k]
            + ": "
            + String(section_pass[k])
            + "/"
            + String(section_total[k])
        )
    print("-----------------------------")
    print("TOTAL: " + String(total_pass) + "/" + String(total) + " passing")
