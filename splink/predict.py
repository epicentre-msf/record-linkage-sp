"""Score the candidate pairs with the saved model. Run from the repository
root:

    uv run python splink/predict.py

Loads splink/model.json, scores every pair the blocking rules reach (the
union of the three passes of model.BLOCKING; a pair is scored once) and
writes them to data-derived/splink/predictions.parquet with the ids, the
match weight (log2 of the posterior odds, prior included), the match
probability and the Bayes factor of every comparison (bf_*; the
geography's term-frequency adjustment separately as bf_tf_adj_geo), and
nothing else: no record values. scripts/05_splink_classify.R turns that
file into the scores and links tables.

Diagnostics to output/splink/: the match-weight histogram and the
unlinkables chart. Splink's comparison viewer and waterfall charts need
the record values retained and are not produced.
"""

import json
import os
import time

from splink import DuckDBAPI, Linker

import common
import model


## run configuration ------------------------------------------------------

common.parse_args("score the candidate pairs with the saved Splink model")
common.setup_logging(os.path.join(common.OUTPUT_DIR, "predict.log"))
print(f"fields: {model.FIELDS}; model: {common.MODEL_JSON}")

con = common.connect()
db_api = DuckDBAPI(connection=con)

# the saved model, with the per-comparison Bayes factors kept in the
# predictions and the record values left out (see model.settings)
with open(common.MODEL_JSON) as f:
    settings = json.load(f)
settings["retain_matching_columns"] = False
settings["retain_intermediate_calculation_columns"] = True
linker = Linker(["d1", "d2"], settings, db_api, input_table_aliases=["d1", "d2"])


## score the candidate pairs ------------------------------------------------

t0 = time.time()
pred = linker.inference.predict()
seconds = round(time.time() - t0)
n_pairs = con.execute(f"select count(*) from {pred.physical_name}").fetchone()[0]
print(f"scored {n_pairs} candidate pairs in {seconds}s")

path = os.path.join(common.DERIVED_DIR, "predictions.parquet")
os.makedirs(os.path.dirname(path), exist_ok=True)
cols = [c for c in pred.columns_escaped if c.strip('"') != "match_key" and not c.strip('"').startswith("tf_")]
con.execute(f"copy (select {', '.join(cols)} from {pred.physical_name}) to '{path}' (format parquet)")
print(f"wrote {path}: {', '.join(c.strip(chr(34)) for c in cols)}")


## aggregate summaries ------------------------------------------------------

# candidate pairs by 2-bit match-weight bin, and above the posterior thresholds
print("\ncandidate pairs by match weight (2-bit bins)")
rows = con.execute(
    f"select 2 * floor(match_weight / 2) as bin, count(*) as n from {pred.physical_name} group by 1 order by 1"
).fetchall()
common.print_table([dict(bin=int(b), pairs=n) for b, n in rows], ["bin", "pairs"])

rows = con.execute(
    f"""select threshold, count(*) filter (where match_probability >= threshold) as pairs
        from {pred.physical_name}, (values (0.5), (0.9), (0.99)) t(threshold) group by 1 order by 1"""
).fetchall()
print()
common.print_table([dict(threshold=t, pairs=n) for t, n in rows], ["threshold", "pairs"])


## diagnostics --------------------------------------------------------------

common.save_chart(
    linker.visualisations.match_weights_histogram(pred), os.path.join(common.OUTPUT_DIR, "match_weights_histogram.html")
)
common.save_chart(linker.evaluation.unlinkables_chart(), os.path.join(common.OUTPUT_DIR, "unlinkables.html"))

common.write_json(
    dict(candidate_pairs=n_pairs, seconds=seconds, written=time.strftime("%Y-%m-%d %H:%M:%S")),
    os.path.join(common.OUTPUT_DIR, "predict.json"),
)
