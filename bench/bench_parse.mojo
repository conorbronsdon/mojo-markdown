"""Throughput benchmark for `render_html` over the CommonMark spec corpus.

Reports wall-clock per full-corpus pass and MB/s. Run compiled for meaningful
numbers: `mojo build -I src bench/bench_parse.mojo -o .bench_parse` then
`./.bench_parse` (or `pixi run bench`). The corpus is the same spec example
set the conformance scoreboard uses, so the benchmark measures the real
parse+render path.
"""
from std.time import perf_counter_ns

from markdown import render_html


def main() raises:
    var raw = open("test/data/spec_cases.txt", "r").read()
    var records = raw.split("\x1e")
    var docs = List[String]()
    var total_bytes = 0
    for r in range(len(records)):
        var fields = records[r].split("\x1f")
        if len(fields) != 4:
            continue
        var md = String(fields[2])
        total_bytes += md.byte_length()
        docs.append(md^)
    var size_mb = Float64(total_bytes) / (1024.0 * 1024.0)
    # Warmup + correctness anchor: rendered output size must stay stable.
    var anchor = 0
    for i in range(len(docs)):
        anchor += render_html(docs[i]).byte_length()
    var iterations = 20
    var start = perf_counter_ns()
    for _ in range(iterations):
        var rendered = 0
        for i in range(len(docs)):
            rendered += render_html(docs[i]).byte_length()
        if rendered != anchor:
            raise Error("inconsistent render")
    var elapsed_ns = perf_counter_ns() - start
    var per_pass_ms = Float64(elapsed_ns) / Float64(iterations) / 1e6
    var mb_per_s = size_mb / (per_pass_ms / 1000.0)
    print("test/data/spec_cases.txt")
    print(t"  {len(docs)} documents, {total_bytes} bytes of markdown:")
    print(t"  {per_pass_ms} ms/corpus pass, {mb_per_s} MB/s")
