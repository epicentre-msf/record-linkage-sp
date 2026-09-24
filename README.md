# Example probabilistic record linkage pipeline with Splink

A pipeline for probabilistic record linkage of suspect cases (D1) to
confirmed outbreak cases (D2) with a two-class Fellegi-Sunter model fitted
in [Splink 4](https://moj-analytical-services.github.io/splink/). The
fields are preprocessed in R, the model is fitted and the candidate pairs
are scored in Splink (Python, DuckDB backend), and the links are
classified and evaluated in R.

The repository is a demonstration of one model: name, age, sex,
geography, occupation and phone number, fitted without any use of the
onset date. It is the model closest to the setting of a future linkage
for which no date anchor will exist (below).

## Purpose

Two surveillance datasets from the same outbreak are linked:

* **D1**: 60,121 suspect cases presenting at health facilities, of which
  2,290 were ultimately confirmed.
* **D2**: 3,479 confirmed cases. Every confirmed D1 case is expected to
  be in D2; the remaining 1,189 D2 records are community deaths that never
  presented to a health facility.

Previous manual work linked 2,207 of the 2,290 confirmed D1 cases to D2.
That **reference linkage** is used for evaluation only: the pipeline was
developed and its parameters fixed without reading it, and it is read for
the first time by the evaluation scripts.

The longer-term goal is a linkage of about 300,000 vaccination records
with about 15,000 surveillance records collected some seven years apart,
with an expected overlap of only 5-10% and few identifying fields (name,
age, sex, health area; occupation and village where recorded). The
present linkage, with its reference, is the feasibility study for that
one. Two consequences shape the pipeline:

* **No date anchor.** Onset dates make D1–D2 linkage much easier (a same-day
  block is almost pure matches), but the vaccination linkage will have
  nothing of the kind. The model therefore compares no date, and its
  parameters are estimated from blocks built on its own fields only.
* **Free-text names.** Names are ordinary free text with a variable number
  of components in a variable order, initials, abbreviations, spelling
  variation and data-entry errors. The name comparison is token-based
  and order-free, and a shared rare token is priced for what it is worth.

## Pipeline

Numbered scripts in `scripts/` run in order; shared functions live in
`R/`; the Splink model lives in `splink/`. The Python project is managed
by [uv](https://docs.astral.sh/uv/) (`pyproject.toml`, `uv.lock`; `uv
sync` creates `.venv/`). Run everything from the repository root.

| step | what it does |
|---|---|
| `scripts/01_ingest.R` | read the raw data, harmonize the two schemas, split the reference linkage off into its own file |
| `scripts/02_preprocess.R` | clean the linkage fields: standardize and tokenize names, canonicalize phone numbers, standardize occupation, tokenize village names, align admin-name spellings across the datasets |
| `scripts/03_audit_fields.R` | aggregate audit of the cleaned phone, occupation and administrative-area fields; writes the occupation mapping tables to `output/` |
| `scripts/04_splink_export.R` | export the cleaned tables to parquet with the blocking keys and the per-token surprisals |
| `splink/train.py` | fit the model: fixed prior, u over the cross product, m by EM on two blocks; saves `splink/model.json` |
| `splink/predict.py` | score every candidate pair with the saved model |
| `scripts/05_splink_classify.R` | two-threshold classification and greedy 1:1 assignment |
| `scripts/06_evaluate.R` | evaluation against the reference linkage |
| `scripts/07_project_vaccination.R` | the same scored pairs re-thresholded under the prior of the vaccination linkage |
| `scripts/08_plots.R` | figures: fitted match weights, precision-recall curve |

```sh
Rscript scripts/01_ingest.R
Rscript scripts/02_preprocess.R
Rscript scripts/03_audit_fields.R           # optional
Rscript scripts/04_splink_export.R
uv run python splink/train.py               # ~45 min the first time (u over the cross product), seconds after
uv run python splink/predict.py             # ~5 min
Rscript scripts/05_splink_classify.R
Rscript scripts/06_evaluate.R
Rscript scripts/07_project_vaccination.R
```

Derived files (`paths()` in `R/paths.R`):

```
data-derived/
  d1_harmonized.rds  d2_harmonized.rds  reference.rds       01
  d1_clean.rds  d2_clean.rds                                02
  splink/
    d1.parquet  d2.parquet                                  04
    u_cache.json                                            train.py
    predictions.parquet                                     predict.py
    fit.rds  scores.rds  links.rds  run.json                05
splink/model.json                                           train.py (committed)
output/splink/                                              charts, logs, evaluation tables
```

`scores.rds` holds one row per candidate pair with `score`, the log2
likelihood ratio of the pair, and `posterior`, the match probability
under the fixed prior. `links.rds` holds the pairs above the review
threshold, ranked, with the 1:1 assignment.

Unit tests run on synthetic data only:

```sh
for t in tests/test_*.R; do Rscript "$t"; done
uv run python tests/test_splink_name_sql.py
```

The last one checks that the DuckDB SQL of the name similarity and of the
shared surprisal reproduces the R reference implementations
(`R/name_similarity.R`, `R/token_surprisal.R`) to machine precision.

## The model

### Fields and comparisons

Each field becomes one Splink comparison with a few discrete levels
(`splink/comparisons.py`). A level's SQL is evaluated top-down and the
first true condition wins; every comparison starts with a *missing* level
(either side empty: no evidence, weight 0) and ends with the
least-agreeing one.

| field | levels |
|---|---|
| **name** | similarity ≥ 0.94 *agree*, ≥ 0.85 *strong*, ≥ 0.75 *weak*, else *disagree*; agree and strong each split by the shared surprisal at 20 and 12 bits, weak at 12 (nine levels; below) |
| **age** | absolute difference 0 / 1-2 / 3-5 / > 5 years, after removing an expected offset (`AGE_OFFSET`, zero here; the elapsed years when the two records are collected years apart) |
| **sex** | agree / disagree |
| **geography** | the finest administrative level on which the pair agrees: village (`adm4`) > health area (`adm3`) > health zone (`adm2`) > province (`adm1`) > different |
| **occupation** (`job`) | the standardized category sets overlap / are disjoint |
| **phone** | a shared canonical number / closest numbers one edit apart (*near*) / disagree |

Geography is one hierarchical variable rather than one comparison per
level because per-level comparisons would be strongly dependent (agreeing
on the health area implies agreeing on the zone and the province), which
breaks the conditional-independence assumption of the model. Village
agreement is a shared place-name token between two order-free token sets,
since one cell may hold several nested places and the two datasets record
different levels. Spelling variants of admin names are aligned across the
datasets at preprocessing, so the scalar levels are exact matches. The
health-area and zone levels carry Splink's term-frequency adjustment:
agreement on a small area is worth more than on a large one, by the ratio
of the level's u to the value's share of records.

Occupation ignores the categories *child* (nearly determined by age,
which is already compared) and *other* (which only means "not in the
list"). The onset date is carried through the cleaned files for the audit
but never compared.

### Candidate pairs

Scoring all 209 million D1 × D2 pairs is unnecessary: a pair that shares
nothing cannot be a match. The candidate pairs are the union of three
cheap blocking passes (`BLOCKING` in `splink/model.py`), so that a true
match survives an error in any single field:

* same health zone;
* a shared name token (full tokens only; tokens on more than 5% of either
  dataset's records are not keys, or they would pair almost everyone with
  almost everyone);
* a shared phone number.

This reaches 27.5 million pairs, 13% of the cross product, and, as the
evaluation shows, all but a handful of the reference pairs.

### The prior

The prior probability that a random D1 × D2 pair is a match is fixed at
2,300 / 209,160,959 ≈ 1.1 × 10⁻⁵: the confirmed D1 cases, all expected in
D2, over the cross product (`LAMBDA` in `splink/model.py`). It is set
from the structure of the problem rather than estimated. With one match
in 90,000 pairs a two-class EM has too little to hold on to, and the
prior is what anchors the model; its influence on the result is a
threshold shift of a few bits, and the sensitivity to it is reported by
`07_project_vaccination.R`.

### Classification

A pair with posterior ≥ 0.9 is a *link*, one in [0.5, 0.9) is for
*review*, below that a non-link (`ACCEPT`, `REVIEW` in `R/classify.R`).
Each D1 record can have at most one D2 counterpart and vice versa, so the
pairs above the review threshold are then assigned one-to-one: ranked by
descending score, each record keeps its highest-ranked pair
(`one_to_one()`).

## How it works

### Name similarity

Names are free text: they vary in the number of components, in
component order ("SMITH, John" vs "Jon Smith"), and in spelling. A naive
whole-string edit distance handles none of this well: "SMITH, John" and
"Jon Smith" differ in most character positions despite plainly being the
same person. Names are therefore compared at the level of *tokens*. Each
name is upper-cased, stripped of accents and punctuation, and split on
whitespace, so "SMITH, John" becomes the token set {SMITH, JOHN}. Token
order is then ignored entirely.

The similarity of two token sets is a symmetric
[Monge-Elkan](https://doi.org/10.1609/aimag.v41i1.5209) average over
[Jaro-Winkler](https://en.wikipedia.org/wiki/Jaro%E2%80%93Winkler_distance)
token similarities: each token in name A is matched to its most similar
token in name B (Jaro-Winkler handles spelling variation, e.g. JON ≈
JOHN), those best-match scores are averaged, the same is done from B to A,
and the two directions are averaged. A single-letter token is treated as
an initial and counts as strong agreement (0.95) with any token sharing
its first letter, so "J. Smith" scores 0.975 against "John Smith". Some
illustrative scores (synthetic names):

| pair | score | comment |
|---|---|---|
| MUKENDI Jean vs Jean Mukendi | 1.000 | reordering is free |
| SMITH, John vs Jon Smith | 0.967 | spelling variant |
| Jon R. Smith vs Smith, Raymond John | 0.961 | initial + reorder + variant |
| Smith, Raymond John vs John Smith | 0.911 | dropped middle name |
| John Smith vs John Martin | 0.794 | namesake: one shared token |
| John Smith vs Paul Jones | 0.413 | unrelated |

The R reference implementation is `name_similarity()` in
`R/name_similarity.R`; the pipeline computes the same quantity in DuckDB
SQL (`NAME_SIM` in `splink/comparisons.py`). Jaro-Winkler is written out
from DuckDB's `jaro_similarity` because DuckDB's own `jaro_winkler_similarity`
applies the usual boost threshold that R's `stringdist` does not.

**Pros.** The measure is robust to exactly the variation expected in true
matches: component reordering costs nothing, initials and typos cost
little, and a dropped or added component degrades the score gracefully
rather than catastrophically. It requires no assumption about which
token is the surname.

**Cons.** All name evidence is reduced to one scalar, so the *quantity*
of evidence is lost: "John Raymond Smith" vs "Smith, John Raymond" and
"Smith" vs "Smith" both score exactly 1.0, though three tokens agreeing is
far less likely by chance than one. Likewise, agreement on a rare token
counts the same as agreement on the most common name in the dataset.
Because each token greedily takes its *best* counterpart, two names
sharing one common token (John Smith / John Martin, 0.794) score
moderately high, and in a large candidate space such namesakes vastly
outnumber true matches, which is why the model bins the similarity into
several levels rather than using a single cutoff. Jaro-Winkler's prefix
bonus also inflates similarity for distinct names with shared stems:
"KABEYA Marie" vs "Kabeya Martine" scores 0.967, indistinguishable from a
true spelling variant.

The rarity half of this weakness is addressed by the shared surprisal.

### Shared surprisal: pricing a rare shared token

The fitted u of a name level (the probability of that level among
non-matches) is one global coincidence rate, but the probability of a
coincidence depends on the value: for a random D1 × D2 pair, sharing token
*t* has probability roughly f_t², so agreement on a rare token is far
stronger evidence than agreement on the most common surname. Each full
token is priced by its *surprisal*, s_t = −log2 f_t bits, with f_t the
share of records (D1 and D2 pooled) containing it, smoothed by adding 2
to each count so that a token seen once, which may be a data-entry
artifact, is worth about 14 bits rather than 16 (`token_surprisal()` in
`R/token_surprisal.R`; only full tokens of two or more characters are
priced, since an initial is shared with every name starting with that
letter). The export writes each record's full tokens and their surprisals
side by side, and the SQL sums the surprisals of the tokens both records
hold exactly in common: the pair's *shared surprisal*.

The three agreeing name levels are then split by it: agree and strong at
20 and 12 bits (two rare tokens / one rare token / only common ones),
weak at 12, giving nine name levels. The cut points were fixed from the
token-frequency histogram before any fit (`SHARED_BITS_BINS` in
`splink/model.py`: 90% of the 31,600 distinct tokens are on four records
or fewer; a token on 17 records is worth about 12 bits, one on 60 records
about 10). Each level has its own m and u, estimated like any other, so
the value of a rare shared token is checked against the data rather than
added as a formula afterwards. A name common in one health zone and rare
elsewhere is still priced by its global frequency.

### Fellegi-Sunter: from comparison levels to a posterior

After comparison, a candidate pair is reduced to a discrete *pattern*
across the six fields, e.g. (name = strong with 12-20 shared bits, age =
0, sex = agree, geography = health area, job = agree, phone = missing).
The model scores it by a likelihood ratio: how much more probable is this
pattern among true matches than among non-matches? For every field and
level that needs the probability of the level *given that the pair is a
match* (the m-probability) and *given that it is not* (the
u-probability). Under the assumption that the fields are conditionally
independent given the match status, the log2 likelihood ratio of a pair
is the sum over its non-missing fields of the *match weight* of its
level, log2(m / u): positive for agreement, negative for disagreement,
larger in magnitude the more surprising the level is under the other
hypothesis. Adding the log2 prior odds gives the posterior log-odds, and
hence the posterior probability that the pair is a match.

`scores.rds` keeps the likelihood ratio (`score`) separate from the
posterior, because the ratio does not depend on the prior: the same
scored pairs can be re-thresholded under the prior of another setting,
which is what the projection does.

The conditional-independence assumption is only approximate. Namesakes
who also live in the same place, household members who share a phone
number and a surname, and other sub-populations of non-matches agree on
several fields at once, and no two-class model prices them exactly. The
remedies used here are structural: the geography as one hierarchical
variable, the age-determined occupation category dropped, the fixed
prior, u from the cross product, and the choice of training blocks below,
plus the review band and the one-to-one assignment at classification.

### Estimation without labels

The pipeline is developed without the reference linkage, so the m- and
u-probabilities have to be estimated from the pairs themselves. The
three steps follow Splink's recommended procedure (`splink/train.py`),
with the prior fixed as above.

**u from the cross product.** The u-probabilities describe non-matches,
and at one match in 90,000 pairs a random pair is a non-match to a very
good approximation. u is computed over the whole cross product rather
than a sample, because the rare name levels (two rare tokens shared) are
reached by only a few hundred non-match pairs, which no manageable sample
would resolve; each level is floored at one pair in the cross product. u
depends only on a comparison's SQL and the data, so it is cached per
comparison (`data-derived/splink/u_cache.json`) and computed once. The
observed u is then corrected for the matches the cross product contains:
at the prior, 2,300 of the pairs are matches, and at the rare agreement
levels they supply a sizeable share of the observed count, which would
overstate u and understate the level's weight by up to a few bits; the
fitted m gives the correction (`correct_u_for_matches`).

**m by EM on match-enriched blocks.** The m-probabilities describe
matches, of which random pairs contain almost none. EM
(expectation-maximisation) estimates them without labels by alternating
two steps: with the current parameters, compute for each pair the
posterior probability that it is a match (E-step); then recount the
level frequencies with every pair contributing fractionally to the match
and non-match tallies according to that posterior (M-step). The
alternation increases the likelihood of the observed patterns at every
round and stops when the estimates settle. It works because of
cross-field correlation: the fields are independent within each class,
so any correlation between them in the pooled data must come from the
mixing, and matches induce exactly that, since a pair agreeing on the
name is disproportionately likely to agree on age, sex, place and phone
as well.

For the alternation to find the matches rather than some other cluster
of correlated agreement, the pairs it runs on must be *match-enriched*,
and the fields it estimates must not be the ones the block was built on
(Splink switches those off, since they agree by construction). Two
blocks, built from the model's own fields only, estimate everything
(`TRAINING_SESSIONS` in `splink/model.py`):

1. **The exact-name block**: pairs whose sorted full name tokens are
   identical. Its non-matches are full namesakes, separated from the
   matches by age, sex, place, occupation and phone, which is exactly what
   this block estimates. The block's match share is free (EM estimates
   it; about 40% of the block's pairs are matches).
2. **The same-area-and-age block**: pairs in the same health area with the
   same age, which estimates the name comparison (and sex) with every
   other m fixed at the first block's value. The match share of this
   block is *not* free: with it free, EM settles on the co-located
   namesakes instead of the matches. It is fixed at N_MATCHES × P(same
   area and age | match) / pairs in the block, with P taken from the
   first fit (the posterior-weighted share of the first block's pairs
   that satisfy the condition). One Splink behaviour has to be worked
   around here: Splink raises an EM session's prior by the Bayes factors
   of the exact-match levels its blocking rule implies even when the
   prior is declared fixed, so the share is set net of that adjustment
   and the script asserts that it held.

**Reference-free checks.** The training script prints, without reading
the reference, the quantities that reveal a fit gone wrong: P(sex agree |
match), which should be near 0.99 for true matches and drops towards 0.5
when a co-located non-match population has merged into the match class;
P(name agree or strong | match), which should be high; the match weights
of every level; and the number of cross-product pairs behind each u, to
flag noisy levels. These are checks on the fit's plausibility, not a
selection rule tuned against the reference.

### Fitted match weights

The fit (`splink/model.json`; `output/splink/match_weights.html` is
Splink's interactive version, `scripts/08_plots.R` a static one). Weights
are log2(m / u) in bits; *pairs behind u* is the number of cross-product
pairs at the level, a measure of how well u is determined.

| field | level | m | u | weight (bits) | pairs behind u |
|---|---|--:|--:|--:|--:|
| name | agree, ≥ 20 shared bits | 0.230 | 4.3e-07 | 19.0 | 619 |
| name | agree, 12-20 | 0.345 | 1.3e-05 | 14.7 | 3,505 |
| name | agree, < 12 | 0.105 | 2.4e-05 | 12.1 | 5,267 |
| name | strong, ≥ 20 | 0.010 | 7.0e-07 | 13.8 | 169 |
| name | strong, 12-20 | 0.089 | 3.7e-05 | 11.2 | 8,000 |
| name | strong, < 12 | 0.066 | 1.6e-03 | 5.4 | 329,136 |
| name | weak, ≥ 12 | 0.007 | 3.3e-05 | 7.7 | 6,982 |
| name | weak, < 12 | 0.145 | 2.8e-02 | 2.4 | 5.8M |
| name | disagree | 0.003 | 0.97 | −8.2 | 203M |
| age | 0 | 0.827 | 0.019 | 5.4 | 4.0M |
| age | 1-2 | 0.091 | 0.068 | 0.4 | 14M |
| age | 3-5 | 0.023 | 0.091 | −2.0 | 19M |
| age | > 5 | 0.058 | 0.82 | −3.8 | 172M |
| sex | agree | 0.993 | 0.50 | 1.0 | 104M |
| sex | disagree | 0.007 | 0.50 | −6.2 | 105M |
| geography | village | 0.624 | 3.2e-03 | 7.6 | 680,278 |
| geography | health area | 0.192 | 8.8e-03 | 4.4 (+ term-frequency adjustment) | 1.8M |
| geography | health zone | 0.077 | 0.11 | −0.5 (+ term-frequency adjustment) | 24M |
| geography | province | 0.067 | 0.61 | −3.2 | 127M |
| geography | different | 0.039 | 0.27 | −2.8 | 56M |
| job | agree | 0.885 | 0.20 | 2.2 | 42M |
| job | disagree | 0.115 | 0.80 | −2.8 | 168M |
| phone | agree | 0.767 | 1.5e-05 | 15.6 | 4,968 |
| phone | near | 0.156 | 7.4e-06 | 14.4 | 1,906 |
| phone | disagree | 0.077 | 1.00 | −3.7 | 209M |

Reading the table: the prior costs 16.5 bits (log2 of 2,300 / 209M), and
a link at posterior 0.9 needs 3.2 bits more, so a pair has to earn about
20 bits. A near-exact name with one rare token shared (14.7) plus the
same age (5.4) and the same village (7.6) is a link; the same name with
only common tokens shared (12.1) and the same health area (4.4) is not,
without a phone number or a village. Note what the shared surprisal
buys: the three *agree* levels differ by 7 bits although the string
similarity is the same. The reference-free checks pass: P(sex agree |
match) 0.99, P(name agree or strong | match) 0.85; the exact-name block
implied 1,336 matches among its pairs and the second block was held at
1,470. The correction of u for the matches in the cross product moved
the top name level by 2.8 bits and the phone levels by 0.3-0.6; it is
essential at the rare levels, where most of the observed pairs are the
matches themselves (619 pairs behind *agree, ≥ 20 bits*, of which some
530 are expected matches).

## Field preparation

All cleaning is in `scripts/02_preprocess.R` and the `R/prep_*.R`
modules; `scripts/03_audit_fields.R` prints the aggregate checks.

**Names** (`R/prep_names.R`): ASCII-folded, upper-cased, punctuation to
spaces, split on whitespace into an order-free token list;
single-character tokens are initials.

**Age and sex**: ages outside [0, 110] and sex values other than
Male/Female become missing.

**Administrative areas** (`R/prep_adm.R`). D1 records province, health
zone, health area and village (`adm1`-`adm4`) in one hierarchy. D2 has
two: `adm1`-`adm3` from the line list itself, and `adm1`-`adm4` joined
from an independent source, the only one with a village. The joined
hierarchy is used (the line-list value only fills its gaps) so that all
four levels come from one consistent source; the audit script checks,
without the reference, that where the two D2 sources disagree the village
sides with the joined one. `adm1`-`adm3` are standardized text, with rare
spelling variants of the province snapped to the frequent value.

The village field is free text at mixed granularity (D1 mostly a single
village or quartier name, D2 often several nested places in one cell:
"CELL. IVATAMA / Q. KIMBULU"), with place-type prefixes (Q., QUARTIER,
CELLULE, AV, VIL), house numbers ("N°258"), kilometre posts ("PK 14") and
numbered subdivisions ("OICHA 1"). It is reduced to an order-free set of
place-name tokens: type words and French function words dropped, house
numbers removed, kilometre posts joined into one token, single characters
dropped. A D1 value "Q. Kimbulu N°45" and a D2 value "CELL. IVATAMA /
Q. KIMBULU" then share the token KIMBULU, which is what the village level
of the geography comparison tests.

After both datasets are cleaned, the `adm2`, `adm3` and village
vocabularies are aligned across them (`align_vocab()`, `align_tokens()`):
a value one dataset uses that the other does not is snapped to the
other's nearest value at Jaro-Winkler ≥ 0.94 (a D1 value only when fewer
than five D1 records carry it, since a frequent D1 value is a real place
D2 has no cases from). Values both datasets use are never touched, so
distinct neighbouring areas with near-identical names stay distinct.

**Occupation** (`R/prep_job.R`). D1 records one free-text field mixing
coded dropdown values with typed text; D2 records one TRUE/FALSE flag per
category with free-text detail columns. Both are mapped to the same 15
categories (child, student, housewife, none, farmer, miner, trade,
transport, artisan, health, traditional healer, religious, security,
professional, other) by keyword rules over the ASCII-folded text,
tolerant of the observed misspellings. Categories describe the
occupation, not the workplace (a guard at a hospital is security), with
one exception: working for the outbreak response counts as health,
mirroring how D2 uses its health-worker flag. A record may carry several
categories, so the representation is a set (`job_cats`), and the
comparison is set overlap. The mapping tables (raw text → categories,
with counts) are written to `output/` by the audit script for review.

**Phone numbers** (`R/prep_phone.R`). Each raw entry is split into its
component numbers (on `, / ; +`), Excel scientific notation is expanded,
a letter O between digits becomes 0, non-digits are dropped, and the
international prefix (243 / 0243 / 00243) and trunk 0 are removed when
what remains is a 9-digit national number. Digit strings of 7-12 digits
are kept, so that a number with a dropped or extra digit survives for the
*near* level. Numbers on more than 10 records across both datasets
(facility or community lines) are dropped from the sets. Canonical
numbers are as protected as the raw field.

## Evaluation against the reference

`scripts/06_evaluate.R` compares the links with the reference linkage.
Each predicted pair falls in one category:

* **correct**: equals a reference pair;
* **wrong partner**: the D1 record has a reference partner, but a
  different D2 record was predicted (a false positive that also leaves a
  false negative);
* **unverifiable**: the D1 record is a confirmed case without a reference
  link (about a hundred), so the prediction could be right or wrong;
* **false positive**: the D1 record is not a confirmed case, so it has no
  true match in D2 (assuming the confirmed set is complete).

Precision is the share of correct predictions among the verifiable ones
(unverifiable excluded from the denominator); recall is the share of the
2,207 reference pairs that were predicted. Both are reported at the two
operating points, links only (posterior ≥ 0.9) and links plus review
(≥ 0.5), each after the 1:1 assignment.

Results (`output/splink/eval_reference.csv`). The blocking reaches
2,193 of the 2,207 reference pairs (99.4%); the 14 it misses share no
name token, zone or phone number and cannot be scored.

| operating point | predicted | correct | wrong partner | unverifiable | false positive | precision | recall |
|---|--:|--:|--:|--:|--:|--:|--:|
| links only (posterior ≥ 0.9, 1:1) | 1,919 | 1,898 | 1 | 1 | 19 | 0.990 | 0.860 |
| links + review (posterior ≥ 0.5, 1:1) | 2,112 | 2,032 | 2 | 2 | 76 | 0.963 | 0.921 |

Of the 2,193 reference pairs that were scored, 1,898 are links, 134 sit
in the review band and 152 score below it; 9 more are outscored by
another pair in the 1:1 assignment. The precision-recall curve across
the whole threshold range is in `output/splink/eval_pr.png`.

The script also recovers, for the reference pairs that were scored but
not linked, the comparison level of every field from the Bayes factors
in the predictions, so that the misses can be characterized without
looking at any record (`output/splink/eval_missed_levels.csv`). Of the
161 missed pairs, 144 have no phone number on one side and 85 no
occupation; 75 agree on the name at *strong* or better but with fewer
than 12 shared bits (a common name with a spelling difference), 30 are
*weak* namesake-like agreements, 10 disagree on the name outright; 68
disagree on age by more than two years; 34 agree only on the zone or
the province. These are the pairs a linkage on these fields cannot
separate from the far more numerous non-matches that look the same,
which is why they stop in the review band or below.

## Caveats

* The reference linkage is very good but neither perfect nor complete,
  so the false-positive and false-negative counts carry some error of
  their own; a few clearly wrong reference links were corrected during
  the work.
* The two-class model prices every non-match by one set of
  u-probabilities. Namesakes who also share a place, and households
  sharing a phone number, agree on more fields than chance predicts, so
  the extreme posteriors are overconfident; the review band and the 1:1
  assignment absorb part of this.
* The fixed prior, the shared-surprisal cut points, the age offset and
  the training blocks were all set before the evaluation, from the
  structure of the problem and aggregate statistics only. They were not
  tuned to the reference, and should be revisited from first principles
  for a new setting rather than copied.
