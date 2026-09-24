"""Shared pieces of the Splink scripts: paths, the DuckDB connection with
the exported tables, argument parsing and a few aggregate summaries.

Privacy: the parquet exports hold name tokens and phone numbers. Nothing
here prints record values; every summary is a count or a parameter.
"""

import argparse
import json
import logging
import math
import os
import sys

import duckdb

sys.path.insert(0, os.path.dirname(__file__))
import model  # noqa: E402

D1_PARQUET = "data-derived/splink/d1.parquet"
D2_PARQUET = "data-derived/splink/d2.parquet"
MODEL_JSON = os.path.join("splink", "model.json")
U_CACHE = os.path.join("data-derived", "splink", "u_cache.json")
DERIVED_DIR = os.path.join("data-derived", "splink")
OUTPUT_DIR = os.path.join("output", "splink")


def parse_args(description):
    p = argparse.ArgumentParser(description=description)
    p.add_argument(
        "--max-pairs",
        type=float,
        default=model.N_D1 * model.N_D2,
        help="pairs for the u estimation; the default is the whole cross product (no sampling), "
        "a smaller value samples records from each dataset",
    )
    p.add_argument("--seed", type=int, default=20260830, help="seed of the u sample when max-pairs samples")
    return p.parse_args()


def connect(threads=8, memory_limit="10GB"):
    """An in-memory DuckDB with d1 and d2 loaded; spills to disk under
    data-derived/splink/tmp when a query exceeds the memory limit."""
    tmp = os.path.abspath(os.path.join(DERIVED_DIR, "tmp"))
    os.makedirs(tmp, exist_ok=True)
    con = duckdb.connect()
    con.execute(f"set threads = {threads}")
    con.execute(f"set memory_limit = '{memory_limit}'")
    con.execute(f"set temp_directory = '{tmp}'")
    con.execute(f"create table d1 as select * from '{D1_PARQUET}'")
    con.execute(f"create table d2 as select * from '{D2_PARQUET}'")
    return con


def setup_logging(path):
    """Splink's log (EM iterations, parameter values), which Splink already
    prints, also to a file; it holds parameters and SQL only, never record
    values."""
    logging.getLogger("splink").setLevel(logging.INFO)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    h = logging.FileHandler(path, mode="w")
    h.setFormatter(logging.Formatter("%(message)s"))
    logging.getLogger("splink").addHandler(h)


def save_chart(chart, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    chart.save(path)


def level_table(settings_dict):
    """One row per (comparison, level) of a saved model: m, u and the match
    weight in bits, in the order of the model. The null level is left out
    (weight 0 by construction)."""
    rows = []
    for c in settings_dict["comparisons"]:
        for lv in c["comparison_levels"]:
            if lv.get("is_null_level"):
                continue
            m, u = lv.get("m_probability"), lv.get("u_probability")
            rows.append(
                dict(
                    variable=c["output_column_name"],
                    level=lv.get("label_for_charts", lv["sql_condition"]),
                    m=m,
                    u=u,
                    weight=None if m is None or u in (None, 0) else math.log2(m / u),
                    tf_adjusted=bool(lv.get("tf_adjustment_column")),
                )
            )
    return rows


def print_table(rows, cols, digits=4):
    """Fixed-width print of a list of dicts (aggregate values only)."""
    fmt = lambda v: "" if v is None else (f"{v:.{digits}g}" if isinstance(v, float) else str(v))  # noqa: E731
    cells = [[fmt(r.get(c)) for c in cols] for r in rows]
    widths = [max(len(c), *(len(row[i]) for row in cells)) for i, c in enumerate(cols)]
    print("  ".join(c.ljust(w) for c, w in zip(cols, widths)))
    for row in cells:
        print("  ".join(v.ljust(w) for v, w in zip(row, widths)))


def write_json(obj, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)
