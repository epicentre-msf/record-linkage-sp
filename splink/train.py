"""Fit the model with Splink (two-class Fellegi-Sunter, DuckDB backend)
and save it as splink/model.json. Run from the repository root:

    uv run python splink/train.py

Follows Splink's recommended three-step estimation, which is what keeps
the two-class model anchored at this match prevalence (one match in
90,000 pairs):

  1. lambda, the prior probability that a random D1 x D2 pair is a match,
     is fixed from the structure of the problem (model.LAMBDA), not
     estimated.
  2. the u-probabilities (the level distribution among non-matches) are
     computed over the whole cross product by default (--max-pairs
     samples instead), then corrected for the matches the cross product
     contains (which matter only at the rare agreement levels; see
     correct_u_for_matches). A comparison's u depends only on its levels'
     SQL and the data, so it is cached per comparison
     (data-derived/splink/u_cache.json) and only the comparisons not in
     the cache are computed.
  3. the m-probabilities (the level distribution among matches) are
     estimated by EM on match-enriched blocks, with u fixed, in the two
     sessions of model.TRAINING_SESSIONS: the exact-name-key block, in
     which the match share is free, then the same-area-and-age block,
     which estimates only the comparisons the first could not (the name),
     with every other m fixed and the block's match share fixed from
     N_MATCHES and the first fit.

Reference-free sanity checks on the fit are printed at the end (session
agreement, m of sex agreement, the match weights, the number of random
pairs behind each u), used as a check and not as a selection rule. Charts
go to output/splink/ as HTML; the saved model holds settings and
parameters only.
"""

import hashlib
import json
import math
import os
import time

from splink import DuckDBAPI, Linker

import common
import model


## run configuration ------------------------------------------------------

args = common.parse_args("fit the model with Splink")
common.setup_logging(os.path.join(common.OUTPUT_DIR, "train.log"))

print(f"fields: {model.FIELDS}")
print(f"lambda {model.LAMBDA:.3e} ({model.N_MATCHES} / {model.N_D1 * model.N_D2})")

con = common.connect()
db_api = DuckDBAPI(connection=con)
settings = model.settings().create_settings_dict(sql_dialect_str="duckdb")


def make_linker(settings_dict):
    return Linker(["d1", "d2"], settings_dict, db_api, input_table_aliases=["d1", "d2"])


## u-probabilities: cached per comparison, computed for the rest ----------


def comparison_signature(c):
    """The u of a comparison depends on its levels' SQL, the term-frequency
    columns and the pair sample; nothing else."""
    key = dict(
        levels=[
            (lv["sql_condition"], bool(lv.get("is_null_level")), lv.get("tf_adjustment_column"))
            for lv in c["comparison_levels"]
        ],
        max_pairs=args.max_pairs,
        seed=args.seed,
    )
    return hashlib.sha1(json.dumps(key, sort_keys=True).encode()).hexdigest()


cache = json.load(open(common.U_CACHE)) if os.path.exists(common.U_CACHE) else {}
missing = [c for c in settings["comparisons"] if comparison_signature(c) not in cache]
print(
    f"u: {len(settings['comparisons']) - len(missing)} comparison(s) from the cache, "
    f"{len(missing)} to compute ({', '.join(c['output_column_name'] for c in missing) or 'none'})"
)

if missing:
    t0 = time.time()
    part = dict(settings, comparisons=missing)
    lk = make_linker(part)
    lk.training.estimate_u_using_random_sampling(max_pairs=args.max_pairs, seed=args.seed)
    print(f"u estimation of {len(missing)} comparison(s) on {args.max_pairs:.3g} pairs: {time.time() - t0:.0f}s")
    for c in lk.misc.save_model_to_json()["comparisons"]:
        cache[comparison_signature(c)] = dict(
            comparison=c["output_column_name"],
            max_pairs=args.max_pairs,
            seed=args.seed,
            u=[lv.get("u_probability") for lv in c["comparison_levels"]],
            written=time.strftime("%Y-%m-%d %H:%M:%S"),
        )
    common.write_json(cache, common.U_CACHE)

# A level no pair reaches has an observed u of zero, and a level a few
# pairs reach has a noisy one; neither can be rarer than one pair among
# all the pairs behind u, which is the floor applied here and after the
# match correction below. Splink would otherwise fill an unobserved level
# with a default.
n_pairs_u = min(args.max_pairs, model.N_D1 * model.N_D2)
U_FLOOR = 1 / n_pairs_u

floored = []
for c in settings["comparisons"]:
    for lv, u in zip(c["comparison_levels"], cache[comparison_signature(c)]["u"]):
        if not lv.get("is_null_level"):
            if not u or u < U_FLOOR:
                floored.append(f"{c['output_column_name']}:{lv.get('label_for_charts')}")
            lv["u_probability"] = max(u or 0, U_FLOOR)
if floored:
    print(f"u floored at one pair in {n_pairs_u:.3g} ({U_FLOOR:.2e}): {', '.join(floored)}")

linker = make_linker(settings)


## m-probabilities by EM in two sessions -----------------------------------


def set_lambda(lk, value):
    lk._settings_obj._probability_two_random_records_match = value


def get_lambda(lk):
    return lk._settings_obj._probability_two_random_records_match


def run_session(lk, name, rule, fix_lambda):
    t0 = time.time()
    s = lk.training.estimate_parameters_using_expectation_maximisation(
        rule, fix_u_probabilities=True, fix_probability_two_random_records_match=fix_lambda
    )
    hist = s._core_model_settings_history
    return dict(
        session=name,
        lambda_fixed=fix_lambda,
        iterations=len(hist) - 1,
        seconds=round(time.time() - t0),
        lambda_in_block=hist[-1].probability_two_random_records_match,
        not_estimated=", ".join(c.output_column_name for c in s._comparisons_that_cannot_be_estimated),
    )


def block_sql(rule):
    return rule.get_blocking_rule("duckdb").blocking_rule_sql


def share_of_matches(lk, first_block_sql, lambda_in_block, condition_sql):
    """P(condition | match), estimated from the current fit on the first
    block: the posterior-weighted share of the block's pairs that satisfy
    the condition. Uses the comparisons estimated so far and the block's
    own match share as the prior."""
    d = lk.misc.save_model_to_json()
    d["comparisons"] = [
        c
        for c in d["comparisons"]
        if all("m_probability" in lv for lv in c["comparison_levels"] if not lv.get("is_null_level"))
    ]
    d["blocking_rules_to_generate_predictions"] = [first_block_sql]
    d["probability_two_random_records_match"] = lambda_in_block
    pred = make_linker(d).inference.predict()
    con.execute("create or replace view d12 as select * from d1 union all select * from d2")
    share = con.execute(
        f"""
        select sum(p.match_probability * ({condition_sql})::int) / sum(p.match_probability)
        from {pred.physical_name} p
        join d12 l on p.unique_id_l = l.unique_id and p.source_dataset_l = l.source_dataset
        join d12 r on p.unique_id_r = r.unique_id and p.source_dataset_r = r.source_dataset
        """
    ).fetchone()[0]
    pred.drop_table_from_database_and_remove_from_cache()
    return share


def count_pairs(condition_sql):
    return con.execute(f"select count(*) from d1 l, d2 r where {condition_sql}").fetchone()[0]


def block_adjustment_bits(lk, rule):
    """Splink starts an EM session at the global prior raised by the Bayes
    factors of the exact-match levels its rule implies (an equi-join on
    adm3 and age implies the adm3 and age-0 levels), whether or not the
    prior is fixed. A fixed match share must therefore be set net of that
    adjustment; a rule Splink cannot map onto levels (the name-key block)
    is adjusted by nothing."""
    from splink.internals.settings import Settings

    levels = Settings._get_comparison_levels_corresponding_to_training_blocking_rule(
        block_sql(rule), "duckdb", lk._settings_obj.core_model_settings.comparisons
    )
    return sum(math.log2(x["level"]._bayes_factor) for x in levels)


def odds(p):
    return p / (1 - p)


def prob(o):
    return o / (1 + o)


sessions = []
fixed = []

# 1. the first block: match share free, everything the block allows estimated
name1, rule1, _ = model.TRAINING_SESSIONS[0]
sessions.append(run_session(linker, name1, rule1, fix_lambda=False))
lambda1 = sessions[-1]["lambda_in_block"]
n1 = count_pairs(block_sql(rule1))
not_estimated1 = sessions[-1]["not_estimated"].split(", ") if sessions[-1]["not_estimated"] else []

# 2. the second block: only the comparisons the first could not estimate,
# every other m fixed, match share fixed from N_MATCHES and the first fit
if not_estimated1:
    name2, rule2, condition2 = model.TRAINING_SESSIONS[1]
    p2 = share_of_matches(linker, block_sql(rule1), lambda1, condition2)
    n2 = count_pairs(condition2)
    lambda2 = model.N_MATCHES * p2 / n2
    print(
        f"{name2} block: {n2} pairs; P({name2} | match) = {p2:.3f} from the {name1} fit;"
        f" match share fixed at {lambda2:.3e} ({model.N_MATCHES * p2:.0f} matches)"
    )
    d = linker.misc.save_model_to_json()
    for c in d["comparisons"]:
        if c["output_column_name"] not in not_estimated1:
            for lv in c["comparison_levels"]:
                if not lv.get("is_null_level"):
                    lv["fix_m_probability"] = True
    linker = make_linker(d)
    adj_bits = block_adjustment_bits(linker, rule2)
    set_lambda(linker, prob(odds(lambda2) / 2**adj_bits))
    print(f"{name2} block: Splink raises the session prior by {adj_bits:.2f} bits for its rule; set net of that")
    sessions.append(run_session(linker, name2, rule2, fix_lambda=True))
    assert abs(sessions[-1]["lambda_in_block"] - lambda2) < 1e-6 * lambda2, (
        "the block's match share was not held at its target"
    )
    set_lambda(linker, model.LAMBDA)
    for cc in linker._settings_obj.core_model_settings.comparisons:
        for lv in cc.comparison_levels:
            lv._fix_m_probability = False
    fixed = [dict(block=name2, p_condition=p2, pairs=n2, lambda_block=lambda2)]
    still = set(not_estimated1) & set(sessions[-1]["not_estimated"].split(", "))
    if still:
        print(f"WARNING: not estimated in any session: {', '.join(sorted(still))}")

print("\nEM sessions (lambda_in_block: match share of the block's pairs)")
common.print_table(sessions, ["session", "lambda_fixed", "iterations", "seconds", "lambda_in_block", "not_estimated"])

assert get_lambda(linker) == model.LAMBDA


## u corrected for the matches among the pairs ----------------------------

# The pairs behind u are not all non-matches: at the prior lambda, n pairs
# hold n * lambda of them (about 2,300 in the cross product), and a
# level's share among them is m, so the observed u_obs = (1 - lambda) u +
# lambda m. The contamination is negligible except at the rare agreement
# levels (rare shared name tokens, phone agree / near), where the matches
# supply a sizeable share of the observed count and u_obs overstates u,
# understating the level's weight by up to a few bits. The correction
# below inverts that relation with the fitted m, floored at U_FLOOR; the
# levels sum to one before and after (up to the floor).
def correct_u_for_matches():
    moved = []
    for cc in linker._settings_obj.core_model_settings.comparisons:
        for lv in cc.comparison_levels:
            if lv.is_null_level or lv.m_probability is None or lv.u_probability is None:
                continue
            u_obs = lv.u_probability
            u_new = max((u_obs - model.LAMBDA * lv.m_probability) / (1 - model.LAMBDA), U_FLOOR)
            if abs(math.log2(u_obs / u_new)) > 0.05:
                moved.append(
                    dict(
                        variable=cc.output_column_name,
                        level=lv.label_for_charts,
                        u_observed=u_obs,
                        u_corrected=u_new,
                        bits=math.log2(u_obs / u_new),
                    )
                )
            lv.u_probability = u_new
    return moved


moved = correct_u_for_matches()
print("\nu corrected for the expected matches among the pairs; levels whose weight moved by more than 0.05 bits:")
common.print_table(moved, ["variable", "level", "u_observed", "u_corrected", "bits"])


## sanity checks -----------------------------------------------------------

rows = common.level_table(linker.misc.save_model_to_json())
u_obs = {
    (c["output_column_name"], lv.get("label_for_charts")): lv.get("u_probability")
    for c in settings["comparisons"]
    for lv in c["comparison_levels"]
    if not lv.get("is_null_level")
}
for r in rows:
    # pairs at the level among those behind u: a level with few is noisy
    r["pairs_u"] = round((u_obs.get((r["variable"], r["level"])) or 0) * n_pairs_u)
    r["matches"] = round(r["m"] * model.N_MATCHES) if r["m"] is not None else None
m_of = {(r["variable"], r["level"]): r["m"] for r in rows}

print("\nSanity checks (reference-free):")
print(f"  m(sex agree) = {m_of[('sex', 'agree')]:.3f}  (expected >= 0.97; ~0.92 means merged co-located non-matches)")
name_hi = sum(m for (v, lv), m in m_of.items() if v == "name" and (lv.startswith("agree") or lv.startswith("strong")))
print(f"  m(name agree or strong, any surprisal) = {name_hi:.3f}  (expected >= 0.8)")
print(f"  {name1} block: match share {lambda1:.4f}, {lambda1 * n1:.0f} matches implied")
sparse = [f"{r['variable']}:{r['level']} ({r['pairs_u']})" for r in rows if r["pairs_u"] < 20]
if sparse:
    print(f"  levels with fewer than 20 pairs behind u (noisy weight): {', '.join(sparse)}")

print("\nFitted parameters (m, u, weight = log2 m/u in bits; pairs_u: pairs at the level behind u; matches: m x N_MATCHES)")
common.print_table(rows, ["variable", "level", "m", "u", "weight", "pairs_u", "matches", "tf_adjusted"])


## charts and the model ----------------------------------------------------

common.save_chart(linker.visualisations.match_weights_chart(), os.path.join(common.OUTPUT_DIR, "match_weights.html"))
common.save_chart(linker.visualisations.m_u_parameters_chart(), os.path.join(common.OUTPUT_DIR, "m_u_parameters.html"))
common.save_chart(
    linker.visualisations.parameter_estimate_comparisons_chart(),
    os.path.join(common.OUTPUT_DIR, "parameter_estimate_comparisons.html"),
)

linker.misc.save_model_to_json(common.MODEL_JSON, overwrite=True)

# the JSON must hold settings and parameters only
with open(common.MODEL_JSON) as f:
    keys = sorted(json.load(f))
print(f"\nsaved {common.MODEL_JSON}; top-level keys: {', '.join(keys)}")

common.write_json(
    dict(
        fields=model.FIELDS,
        lambda_=model.LAMBDA,
        n_matches=model.N_MATCHES,
        max_pairs=args.max_pairs,
        seed=args.seed,
        age_offset=model.AGE_OFFSET,
        shared_bits_bins=model.SHARED_BITS_BINS,
        sessions=sessions,
        fixed_share=fixed,
        written=time.strftime("%Y-%m-%d %H:%M:%S"),
    ),
    os.path.join(common.OUTPUT_DIR, "train.json"),
)
