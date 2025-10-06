#!/usr/bin/env python3
"""Extract best (fastest) grid-search configurations per MRR cut.

Reads a single TSV file with header columns including:
k\tnprobe\tthresh\tthresh_query\tn_doc_to_score\tout_second_stage\tavg_query_time_ns\tmrr@10\trecall@10

For each MRR cut (user-specified or generated from unique mrr@10 values), the script selects
the row with the minimal `avg_query_time_ns` among rows whose `mrr@10` >= cut.

Writes results as TSV to stdout or to a file.
"""

from __future__ import annotations

import argparse
import csv
import sys
from typing import Dict, List, Tuple


def parse_args():
    p = argparse.ArgumentParser(description="Extract fastest configuration per MRR cut from a single TSV file")
    p.add_argument("input", nargs="?", default="grid_results_m32.tsv", help="Input TSV file path")
    p.add_argument("--cuts", nargs="*", type=float, help="MRR cut values (e.g. 0.38 0.39). If omitted, uses unique mrr@10 values from file sorted ascending")
    p.add_argument("--output", "-o", help="Output TSV file path (default stdout)")
    p.add_argument("--mrr-col", default="mrr@10", help="Name of the MRR column in header")
    p.add_argument("--time-col", default="avg_query_time_ns", help="Name of the time column in header")
    p.add_argument("--min-rows", type=int, default=1, help="Minimum number of rows required to consider a cut (unused, reserved)")
    return p.parse_args()


def read_tsv(filepath: str) -> Tuple[List[str], List[Dict[str, str]]]:
    with open(filepath, "r", newline="") as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        header = reader.fieldnames or []
        rows = [row for row in reader]
    return header, rows


def to_float_safe(s: str) -> float:
    try:
        return float(s)
    except Exception:
        return float("nan")


def select_best_for_cut(rows: List[Dict[str, str]], mrr_col: str, time_col: str, cut: float) -> Dict[str, str] | None:
    # Filter rows with mrr > cut (strictly greater as requested)
    filtered = [r for r in rows if to_float_safe(r.get(mrr_col, "nan")) >= cut]
    if not filtered:
        return None
    # Select row with minimal avg time
    best = min(filtered, key=lambda r: to_float_safe(r.get(time_col, "nan")))
    return best


def main():
    args = parse_args()
    header, rows = read_tsv(args.input)

    if args.mrr_col not in header:
        print(f"Error: MRR column '{args.mrr_col}' not found in input header", file=sys.stderr)
        sys.exit(2)
    if args.time_col not in header:
        print(f"Error: time column '{args.time_col}' not found in input header", file=sys.stderr)
        sys.exit(2)

    # Determine cuts. Default: range 0.39 -> 0.404 step 0.001 inclusive
    if args.cuts:
        cuts = sorted(set(args.cuts))
    else:
        start = 0.39
        end = 0.404
        step = 0.001
        steps = int(round((end - start) / step)) + 1
        cuts = [round(start + i * step, 6) for i in range(0, steps)]

    results: List[Dict[str, str]] = []
    for cut in cuts:
        best = select_best_for_cut(rows, args.mrr_col, args.time_col, cut)
        if best is None:
            # write placeholder row with '/' for unavailable values
            empty_row = {k: '/' for k in header}
            empty_row['mrr_cut'] = f"{cut:.6f}"
            # ensure time column shows '/'
            empty_row[args.time_col] = '/'
            results.append(empty_row)
            continue
        out = dict(best)
        out["mrr_cut"] = f"{cut:.6f}"
        results.append(out)

    # Output header: mrr_cut + original header
    out_header = ["mrr_cut"] + header

    if args.output:
        out_f = open(args.output, "w", newline="")
    else:
        out_f = sys.stdout

    writer = csv.DictWriter(out_f, fieldnames=out_header, delimiter="\t")
    writer.writeheader()
    for r in results:
        # Ensure all header fields exist
        row = {k: r.get(k, "") for k in out_header}
        writer.writerow(row)

    if args.output:
        out_f.close()


if __name__ == "__main__":
    main()
