"""Test that the DuckDB SQL of splink/comparisons.py equals its R
reference implementations, on synthetic names only.

Run from the repository root: uv run python tests/test_splink_name_sql.py
(R must be on the path; parts 2 and 3 call Rscript).

1. The name similarity on the illustrative pairs of the README table, to
   three decimals.
2. The name similarity on random synthetic token pairs (lengths 1-4,
   tokens drawn from a small made-up vocabulary with spelling variants
   and initials), against name_similarity() in R/name_similarity.R, to
   1e-9.
3. The shared surprisal on synthetic records, against token_surprisal()
   in R/token_surprisal.R, to 1e-9.
"""

import csv
import os
import random
import subprocess
import sys
import tempfile

import duckdb

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "splink"))
from comparisons import NAME_SIM  # noqa: E402

ROOT = os.path.join(os.path.dirname(__file__), "..")


def sim_duckdb(pairs):
    """NAME_SIM for a list of (tokens_a, tokens_b) via DuckDB, in order."""
    con = duckdb.connect()
    con.execute('create table p (i integer, "name_tokens_l" varchar[], "name_tokens_r" varchar[])')
    con.executemany("insert into p values (?, ?, ?)", [(i, a, b) for i, (a, b) in enumerate(pairs)])
    return [r[0] for r in con.execute(f"select {NAME_SIM} from p order by i").fetchall()]


def tokens(name):
    return name.upper().replace(",", " ").replace(".", " ").split()


## 1 the README table ------------------------------------------------------
readme = [
    (("MUKENDI Jean", "Jean Mukendi"), 1.000),
    (("SMITH, John", "Jon Smith"), 0.967),
    (("Jon R. Smith", "Smith, Raymond John"), 0.961),
    (("Smith, Raymond John", "John Smith"), 0.911),
    (("John Smith", "John Martin"), 0.794),
    (("John Smith", "Paul Jones"), 0.413),
]
got = sim_duckdb([(tokens(a), tokens(b)) for (a, b), _ in readme])
for ((a, b), want), g in zip(readme, got):
    assert round(g, 3) == want, f"{a} vs {b}: {g:.4f} != {want}"

## 2 random synthetic pairs against R --------------------------------------
vocab = [
    "JOHN", "JON", "JOHNNY", "SMITH", "SMYTH", "SMIHT", "RAYMOND", "RAY", "MARTIN",
    "MARTINE", "PAUL", "PAULINE", "JONES", "JEAN", "MUKENDI", "MUKENDY", "KAVUGHO",
    "KAMBALE", "KAMBALA", "MASIKA", "MASIKO", "A", "J", "K", "M", "S", "AB", "ABC",
]
rng = random.Random(20260921)
pairs = []
for _ in range(2000):
    a = [rng.choice(vocab) for _ in range(rng.randint(1, 4))]
    b = [rng.choice(vocab) for _ in range(rng.randint(1, 4))]
    if rng.random() < 0.3:  # share a token, as namesakes and matches do
        b[rng.randrange(len(b))] = rng.choice(a)
    pairs.append((a, b))

got = sim_duckdb(pairs)

with tempfile.TemporaryDirectory() as tmp:
    inp = os.path.join(tmp, "pairs.csv")
    out = os.path.join(tmp, "sim.csv")
    with open(inp, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["a", "b"])
        for a, b in pairs:
            w.writerow([" ".join(a), " ".join(b)])
    r_code = f"""
    suppressPackageStartupMessages(library(data.table))
    source("R/utils.R"); source("R/prep_names.R"); source("R/name_similarity.R")
    p <- read.csv("{inp}", stringsAsFactors = FALSE)
    s <- name_similarity(name_tokens(p$a), name_tokens(p$b))
    write.csv(data.frame(s = s), "{out}", row.names = FALSE)
    """
    subprocess.run(["Rscript", "-e", r_code], cwd=ROOT, check=True)
    with open(out) as f:
        want = [float(r["s"]) for r in csv.DictReader(f)]

assert len(want) == len(got)
worst = max(abs(g - w) for g, w in zip(got, want))
assert worst < 1e-9, f"max |duckdb - R| = {worst}"
print(f"ok: README table matches; {len(pairs)} random synthetic pairs, max abs diff {worst:.1e}")

## 3 shared surprisal against R ---------------------------------------------
# SHARED_BITS (the summed surprisal of the exactly shared full tokens) must
# equal, for every pair, the sum of token_surprisal()'s s over the full
# tokens the two records share. Synthetic records only: a vocabulary of
# made-up tokens, frequencies from the synthetic tables themselves.
from comparisons import SHARED_BITS  # noqa: E402

rng = random.Random(20260922)
full_vocab = [t for t in vocab if len(t) >= 2]
recs1 = [[rng.choice(full_vocab) for _ in range(rng.randint(1, 3))] for _ in range(300)]
recs2 = [[rng.choice(full_vocab) for _ in range(rng.randint(1, 3))] for _ in range(100)]
# a few initials, which must never count
recs1 = [r + (["J"] if rng.random() < 0.2 else []) for r in recs1]

with tempfile.TemporaryDirectory() as tmp:
    f1, f2, out = (os.path.join(tmp, n) for n in ("d1.csv", "d2.csv", "bits.csv"))
    for path, recs in ((f1, recs1), (f2, recs2)):
        with open(path, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["row", "name"])
            for i, r in enumerate(recs):
                w.writerow([i + 1, " ".join(r)])
    r_code = f"""
    suppressPackageStartupMessages(library(data.table))
    source("R/utils.R"); source("R/prep_names.R"); source("R/token_surprisal.R")
    d1 <- read.csv("{f1}", stringsAsFactors = FALSE); d2 <- read.csv("{f2}", stringsAsFactors = FALSE)
    d1$name_tokens <- name_tokens(d1$name); d2$name_tokens <- name_tokens(d2$name)
    t1 <- token_long(d1); t2 <- token_long(d2)
    tf <- token_surprisal(t1, t2, nrow(d1) + nrow(d2))
    # every pair of the cross product: the surprisals of the tokens both
    # records hold, summed (0 when none)
    setnames(t1, "row", "row_1"); setnames(t2, "row", "row_2")
    t1 <- tf[, .(token, s)][t1, on = "token"]
    pairs <- CJ(row_1 = d1$row, row_2 = d2$row)
    x <- t1[pairs, on = "row_1", allow.cartesian = TRUE, nomatch = NULL]
    x <- x[t2, on = .(row_2, token), nomatch = NULL]
    bits <- x[, .(bits = sum(s)), by = .(row_1, row_2)]
    all <- merge(pairs, bits, by = c("row_1", "row_2"), all.x = TRUE)
    all[is.na(bits), bits := 0]
    fwrite(all[order(row_1, row_2)], "{out}")
    fwrite(tf, "{os.path.join(tmp, 'tf.csv')}")
    """
    subprocess.run(["Rscript", "-e", r_code], cwd=ROOT, check=True)
    with open(out) as f:
        want = {(int(r["row_1"]), int(r["row_2"])): float(r["bits"]) for r in csv.DictReader(f)}
    with open(os.path.join(tmp, "tf.csv")) as f:
        surprisal = {r["token"]: float(r["s"]) for r in csv.DictReader(f)}

# the export's columns: distinct full tokens and their surprisals, aligned
def tf_cols(r):
    toks = list(dict.fromkeys(t for t in r if len(t) >= 2))
    return toks, [surprisal[t] for t in toks]

con = duckdb.connect()
con.execute('create table d1 (row integer, "tf_tokens" varchar[], "tf_bits" double[])')
con.execute('create table d2 (row integer, "tf_tokens" varchar[], "tf_bits" double[])')
con.executemany("insert into d1 values (?, ?, ?)", [(i + 1, *tf_cols(r)) for i, r in enumerate(recs1)])
con.executemany("insert into d2 values (?, ?, ?)", [(i + 1, *tf_cols(r)) for i, r in enumerate(recs2)])
got = con.execute(
    f"""select l.row, r.row, {SHARED_BITS}
        from (select row, "tf_tokens" as "tf_tokens_l", "tf_bits" as "tf_bits_l" from d1) l,
             (select row, "tf_tokens" as "tf_tokens_r" from d2) r
        order by 1, 2"""
).fetchall()
assert len(got) == len(want) == len(recs1) * len(recs2)
worst = max(abs(float(b) - want[(i, j)]) for i, j, b in got)
assert worst < 1e-9, f"max |duckdb - R| shared surprisal = {worst}"
n_shared = sum(1 for _, _, b in got if b > 0)
print(f"ok: shared surprisal matches R on {len(got)} synthetic pairs ({n_shared} sharing a token), max abs diff {worst:.1e}")
