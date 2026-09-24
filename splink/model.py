"""The model: its fields as Splink comparisons, the prior, the blocking
rules that choose the candidate pairs, and the blocks on which the
m-probabilities are estimated by EM.

Fields: name, age, sex, geography (province > health zone > health area >
village), occupation, phone number. The onset date is not compared: the
model is meant to resemble the future vaccination linkage, where the two
records of a person are collected years apart and no date could serve as
an anchor, so nothing here uses a date, neither in the comparisons nor
in the training blocks (the "own-field" protocol: the parameters are
estimated from the model's own fields only, the way a linkage with those
fields would have to estimate them).
"""

from splink import SettingsCreator, block_on
from splink.blocking_rule_library import CustomRule

import comparisons as cmp

FIELDS = "name, age, sex, adm1-4, job, phone"

# Prior probability that a random D1 x D2 pair is a match: about 2,300
# matches (the 2,290 confirmed D1 cases, all expected in D2) among
# 60,121 x 3,479 = 209.2M pairs. Set from the structure of the problem,
# not estimated: with one match in 90,000 pairs a two-class EM has too
# little to hold on to, and the prior is what anchors the model.
N_MATCHES = 2300
N_D1 = 60121
N_D2 = 3479
LAMBDA = N_MATCHES / (N_D1 * N_D2)

# Expected D2 minus D1 age of a true match (comparisons.age): zero here,
# where both datasets record the same disease episode; the elapsed years
# between the two collections when they are years apart.
AGE_OFFSET = 0

# Cut points (bits, descending) of the shared surprisal in the name
# comparison (comparisons.name), fixed from the token-frequency histogram
# of the cleaned data before any fit (aggregate statistics only): with
# 63,600 records and the +2 smoothing of R/token_surprisal.R a token seen
# once is worth 14.4 bits, one on 17 records 11.7, on 60 records 10, on
# 600 records 6.6; 90% of the 31,600 tokens are on 4 records or fewer.
#   >= 20   two rare tokens shared (each on ~60 records or fewer), or a
#           singleton plus a moderately rare token
#   12-20   one rare token (on ~15 records or fewer), or two moderately
#           rare ones
#   < 12    only moderately rare or common tokens shared, or none
SHARED_BITS_BINS = (20, 12)


## blocking rules ---------------------------------------------------------

# Prediction blocking: the candidate pairs are the union of three cheap
# passes, so that a true match survives an error in any single field.
# Splink scores the union once (a pair reached by a later rule is excluded
# if an earlier rule already reached it).
#   adm2    same health zone
#   token   a shared name token (full tokens only; tokens on more than 5%
#           of either dataset are not keys: scripts/04_splink_export.R)
#   phone   a shared canonical phone number
BLOCKING = [
    block_on("adm2"),
    block_on("block_tokens", arrays_to_explode=["block_tokens"]),
    block_on("phones", arrays_to_explode=["phones"]),
]

# EM training blocks: match-enriched subsets in which the two-class EM is
# stable. A comparison whose input columns appear in the rule is not
# estimated in that session (Splink deactivates it), so each session
# estimates the others, and every field is estimated in at least one.
# Splink deactivates by column name, so a rule that must switch the name
# comparison off names name_tokens explicitly (a no-op condition).
#
#   key     the same sorted full-token name (name_key): estimates
#           everything but the name, with the match share free. The
#           block's non-matches are full namesakes, separated from the
#           matches by age, sex and place.
#   area    same health area and same age: estimates the name (and sex)
#           with every other m fixed at the key-block value and the match
#           share fixed at N_MATCHES x P(same area and age | match) / pairs
#           in the block, P from the key-block fit. With the match share
#           free, EM finds the co-located namesakes instead of the
#           matches; fixing it from the first fit is the cure.
EM_BLOCKS = {
    "key": CustomRule('l."name_key" = r."name_key" and l."name_tokens" is not null and r."name_tokens" is not null'),
    "area": block_on("adm3", "age"),
}

# The EM sessions in order: (name, blocking rule, condition SQL on l./r.
# for the match-share fixing, or None when the block's match share is
# free). The second session estimates only the comparisons the first
# could not.
TRAINING_SESSIONS = [
    ("key", EM_BLOCKS["key"], None),
    ("area", EM_BLOCKS["area"], 'l."adm3" = r."adm3" and l."age" = r."age"'),
]


def comparisons():
    return [cmp.name(SHARED_BITS_BINS), cmp.age(AGE_OFFSET), cmp.sex, cmp.geo(4), cmp.job, cmp.phone]


def settings():
    return SettingsCreator(
        link_type="link_only",
        comparisons=comparisons(),
        blocking_rules_to_generate_predictions=BLOCKING,
        probability_two_random_records_match=LAMBDA,
        em_convergence=1e-4,
        max_iterations=200,
        # the scored pairs keep ids, weights and the per-comparison Bayes
        # factors (bf_*), not the record values: nothing in the predictions
        # or the charts is a name or a phone number (Splink's comparison
        # vector columns come only with the record values, so the bf_*
        # columns stand in for them)
        retain_matching_columns=False,
        retain_intermediate_calculation_columns=True,
    )
