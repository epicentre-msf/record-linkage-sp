"""Comparison definitions: every field becomes a Splink comparison whose
levels are written as DuckDB SQL. Splink evaluates the levels top-down and
the first true condition wins, so each list starts with the null level
("missing": either side empty, no evidence, weight 0) and ends with the
else level ("disagree" / ">5" / "different").

The name similarity and the shared surprisal are checked against their R
reference implementations (R/name_similarity.R, R/token_surprisal.R) on
synthetic names by tests/test_splink_name_sql.py.

Set-valued fields (name tokens, village tokens, occupation categories,
phone numbers) arrive as DuckDB lists (scripts/04_splink_export.R writes
empty sets as NULL), so the null tests below only need `is null`; the
`len() = 0` guards are kept for safety.
"""

import splink.comparison_level_library as cll
import splink.comparison_library as cl


## name -------------------------------------------------------------------

# Symmetric Monge-Elkan over Jaro-Winkler token similarities, as in
# name_similarity() (R/name_similarity.R): for each token of one name the best
# match among the tokens of the other, averaged, in both directions, then
# averaged. A single-character token (an initial) that equals the first
# letter of the other token counts at least 0.95.
#
# Jaro-Winkler is written out from DuckDB's jaro_similarity because R's
# stringdist (method "jw", p = 0.1) adds the prefix bonus to every pair,
# while DuckDB's jaro_winkler_similarity applies the usual boost threshold
# (no bonus below a Jaro of 0.7); the two differ on dissimilar tokens that
# share a first letter. The common prefix counts up to four characters.
def _prefix(t, s):
    return (
        f"case when {t}[1:1] = {s}[1:1] then case when {t}[1:2] = {s}[1:2] "
        f"then case when {t}[1:3] = {s}[1:3] then case when {t}[1:4] = {s}[1:4] "
        f"then 4 else 3 end else 2 end else 1 end else 0 end"
    )


def _jw(t, s):
    return f"(jaro_similarity({t}, {s}) + 0.1 * {_prefix(t, s)} * (1 - jaro_similarity({t}, {s})))"


def _token_sim(t, s):
    return (
        f"greatest({_jw(t, s)}, "
        f"case when (length({t}) = 1 or length({s}) = 1) and {t}[1] = {s}[1] "
        f"then 0.95 else 0.0 end)"
    )


def _me_one_way(a, b):
    return f"list_avg(list_transform({a}, t -> list_max(list_transform({b}, s -> {_token_sim('t', 's')}))))"


NAME_SIM = (
    "(" + _me_one_way('"name_tokens_l"', '"name_tokens_r"') + " + "
    + _me_one_way('"name_tokens_r"', '"name_tokens_l"') + ") / 2"
)

# Shared surprisal: the summed surprisal (bits) of the full tokens both
# records hold exactly, each token priced by its pooled smoothed frequency
# (tf_tokens / tf_bits from scripts/04_splink_export.R, computed by
# token_surprisal() in R/token_surprisal.R). list_intersect returns the
# distinct common tokens; a pair with no common full token, or a record
# without full tokens, sums to 0. Initials and fuzzy-matched tokens
# contribute nothing. Splink finds the columns a level needs by parsing
# its SQL, and does not look inside lambdas, so tf_bits is also named
# outside the lambda in a term that is always 0.
SHARED_BITS = (
    '(coalesce(list_sum(list_transform(list_intersect("tf_tokens_l", "tf_tokens_r"), '
    't -> list_extract("tf_bits_l", list_position("tf_tokens_l", t)))), 0)'
    ' + 0 * coalesce(len("tf_bits_l"), 0))'
)


def empty(col):
    return f'("{col}_l" is null or "{col}_r" is null or len("{col}_l") = 0 or len("{col}_r") = 0)'


def name(bins):
    """The name comparison: four similarity levels (agree >= 0.94, strong
    >= 0.85, weak >= 0.75, disagree; "weak" captures the very common
    share-one-token namesake signature, "strong" typos and dropped
    components, "agree" near-exact), the first three split by the shared
    surprisal of the pair, so that the same similarity is priced
    differently when the tokens the two names have in common are rare.
    `bins` are the surprisal cut points in descending order
    (model.SHARED_BITS_BINS): with (20, 12) the agree and strong
    levels split into >= 20 / 12-20 / < 12 bits and the weak level into
    >= 12 / < 12. Each level gets its own m and u, estimated like any
    other, so the pricing of a rare shared token is checked against the
    data rather than derived from a formula; the term-frequency
    adjustment lives in the levels, not in a post-hoc delta.

    A level's SQL repeats the similarity expression, so the comparison
    vector column is computed once per pair by DuckDB's common
    subexpression handling."""
    hi, lo = bins
    levels = [cll.CustomLevel(empty("name_tokens"), "missing").configure(is_null_level=True)]
    for label, thr in (("agree", 0.94), ("strong", 0.85)):
        levels += [
            cll.CustomLevel(f"{NAME_SIM} >= {thr} and {SHARED_BITS} >= {hi}", f"{label}_bits{hi}"),
            cll.CustomLevel(f"{NAME_SIM} >= {thr} and {SHARED_BITS} >= {lo}", f"{label}_bits{lo}"),
            cll.CustomLevel(f"{NAME_SIM} >= {thr}", label),
        ]
    levels += [
        cll.CustomLevel(f"{NAME_SIM} >= 0.75 and {SHARED_BITS} >= {lo}", f"weak_bits{lo}"),
        cll.CustomLevel(f"{NAME_SIM} >= 0.75", "weak"),
        cll.ElseLevel().configure(label_for_charts="disagree"),
    ]
    return cl.CustomComparison(output_column_name="name", comparison_levels=levels)


## age, sex ---------------------------------------------------------------


def age(offset):
    """Absolute age difference, binned (0 / 1-2 / 3-5 / > 5), after
    removing the expected offset between the two records' ages
    (model.AGE_OFFSET): the D2 age minus the D1 age that a true match
    should show. Zero here, where both datasets record the same episode;
    for records collected years apart (the vaccination linkage) it is the
    elapsed time, so that "agree" means "consistent with the elapsed
    time" rather than "identical". With a zero offset the 0 level is an
    exact match, which Splink recognises for training blocks on age."""
    diff = f'abs("age_r" - "age_l" - ({offset}))'
    zero = cll.ExactMatchLevel("age") if offset == 0 else cll.CustomLevel(f"{diff} = 0")
    return cl.CustomComparison(
        output_column_name="age",
        comparison_levels=[
            cll.NullLevel("age"),
            zero.configure(label_for_charts="0"),
            cll.CustomLevel(f"{diff} <= 2", "1-2"),
            cll.CustomLevel(f"{diff} <= 5", "3-5"),
            cll.ElseLevel().configure(label_for_charts=">5"),
        ],
    )


sex = cl.CustomComparison(
    output_column_name="sex",
    comparison_levels=[
        cll.NullLevel("sex"),
        cll.ExactMatchLevel("sex").configure(label_for_charts="agree"),
        cll.ElseLevel().configure(label_for_charts="disagree"),
    ],
)


## geography --------------------------------------------------------------

def geo(depth, tf_levels=("adm3", "adm2")):
    """One hierarchical variable, the finest agreeing admin level (village
    adm4 > health area adm3 > health zone adm2 > province adm1 >
    different), rather than one comparison per level: separate per-level
    comparisons would be strongly dependent (adm3 agreement implies adm2
    and adm1 agreement), which breaks the conditional-independence
    assumption. "missing" only when no level is comparable. Village
    agreement is a shared place-name token between two order-free token
    sets (R/prep_adm.R): one cell may hold several nested places and the
    two datasets record different levels. Spelling variants of admin
    names are aligned across the datasets at preprocessing, so the scalar
    levels are exact. The scalar levels named in `tf_levels` carry Splink's
    term-frequency adjustment: agreement on a health area (or zone) that
    holds few records is worth more than agreement on a large one, by
    the ratio of the level's u to the value's share of records. The
    village level is a token-set overlap, which Splink's adjustment (a
    scalar exact match) cannot price; it keeps its global weight."""
    scalar = [f'("adm{k}_l" is null or "adm{k}_r" is null)' for k in range(1, min(depth, 3) + 1)]
    not_comparable = scalar + ([empty("adm4_tokens")] if depth >= 4 else [])
    levels = [cll.CustomLevel(" and ".join(not_comparable), "missing").configure(is_null_level=True)]
    if depth >= 4:
        levels.append(cll.CustomLevel('list_has_any("adm4_tokens_l", "adm4_tokens_r")', "adm4"))
    for k in range(min(depth, 3), 0, -1):
        lv = cll.ExactMatchLevel(f"adm{k}").configure(label_for_charts=f"adm{k}")
        if f"adm{k}" in tf_levels:
            lv = lv.configure(tf_adjustment_column=f"adm{k}")
        levels.append(lv)
    levels.append(cll.ElseLevel().configure(label_for_charts="different"))
    return cl.CustomComparison(output_column_name="geo", comparison_levels=levels)


## occupation and phone ---------------------------------------------------

# Set overlap of the standardized occupation categories (R/prep_job.R),
# after the export dropped the categories that carry no independent
# information (JOB_IGNORE: "child", nearly determined by age, and "other").
job = cl.CustomComparison(
    output_column_name="job",
    comparison_levels=[
        cll.CustomLevel(empty("job_cats"), "missing").configure(is_null_level=True),
        cll.CustomLevel('list_has_any("job_cats_l", "job_cats_r")', "agree"),
        cll.ElseLevel().configure(label_for_charts="disagree"),
    ],
)

# Set comparison of the canonical phone numbers (R/prep_phone.R): "agree"
# if the records share a number, "near" if their closest numbers differ by
# a single edit (one substituted, dropped, added or transposed digit: the
# typical data-entry error, and rare between unrelated numbers),
# "disagree" otherwise.
MIN_DL = (
    'list_min(list_transform("phones_l", a -> '
    'list_min(list_transform("phones_r", b -> damerau_levenshtein(a, b)))))'
)
phone = cl.CustomComparison(
    output_column_name="phone",
    comparison_levels=[
        cll.CustomLevel(empty("phones"), "missing").configure(is_null_level=True),
        cll.CustomLevel('list_has_any("phones_l", "phones_r")', "agree"),
        cll.CustomLevel(f"{MIN_DL} = 1", "near"),
        cll.ElseLevel().configure(label_for_charts="disagree"),
    ],
)
