# Evaluation against the reference linkage (data-derived/reference.rds).
#
# Only the evaluation scripts (scripts/06_evaluate.R,
# scripts/07_project_vaccination.R, scripts/08_plots.R) source this file:
# nothing in the pipeline proper may read the reference. Only row keys
# leave these functions; the protected ids stay inside reference.rds.
#
# Prediction categories against the reference:
#   correct        -- predicted pair equals a reference pair
#   wrong_partner  -- the D1 record has a reference partner, but a different
#                     D2 record was predicted (an FP that also leaves an FN)
#   unverifiable   -- the D1 record is a confirmed case without a reference
#                     link (the ~100 never linked); could be right or wrong
#   false_positive -- the D1 record is not a confirmed case, so it has no
#                     true match in D2 (assuming the confirmed set is complete)
#
# precision_known excludes the unverifiable predictions from the
# denominator; precision_lo / precision_hi count them as all wrong / all
# right; recall_known is against the reference pairs.
#
# Requires: dplyr, tibble.

# Reference pairs (row_1, row_2) and confirmed D1 rows from reference.rds.
# Only D1 records whose id_d2 resolves to a D2 record give a reference pair.
reference_pairs <- function(ref) {
  pairs <- ref$d1 |>
    dplyr::filter(!is.na(id_d2)) |>
    dplyr::inner_join(ref$d2, by = "id_d2") |>
    dplyr::select(row_1 = row_d1, row_2 = row_d2)
  stopifnot(!anyDuplicated(pairs$row_1))

  confirmed <- ref$d1$row_d1[!is.na(ref$d1$order_d1)]

  list(
    pairs = tibble::as_tibble(pairs),
    confirmed = confirmed,
    unverifiable = setdiff(confirmed, pairs$row_1)
  )
}

# Reference category of every predicted pair (see the header); `truth` is
# the list from reference_pairs().
categorize <- function(pred, truth) {
  pred |>
    dplyr::left_join(dplyr::rename(truth$pairs, true_row_2 = row_2), by = "row_1") |>
    dplyr::mutate(
      category = dplyr::case_when(
        is.na(true_row_2) & row_1 %in% truth$confirmed ~ "unverifiable",
        is.na(true_row_2) ~ "false_positive",
        row_2 == true_row_2 ~ "correct",
        .default = "wrong_partner"
      )
    ) |>
    dplyr::select(-true_row_2)
}

# Counts and metrics of one prediction set against the reference.
metrics_ref <- function(pred, truth) {
  x <- categorize(pred, truth)
  n <- function(k) sum(x$category == k)

  tibble::tibble(
    predicted = nrow(x),
    correct = n("correct"),
    wrong_partner = n("wrong_partner"),
    unverifiable = n("unverifiable"),
    false_positive = n("false_positive"),
    precision_known = correct / (predicted - unverifiable),
    precision_lo = correct / predicted,
    precision_hi = (correct + unverifiable) / predicted,
    recall_known = correct / nrow(truth$pairs)
  )
}

# Counts and metrics of one prediction set against another prediction set
# taken as truth (one pair per D1 record, e.g. the full model's 1:1 links):
# correct (same pair), wrong_partner (the D1 record is linked to another D2
# record in `base`) and extra (the D1 record is not linked in `base`).
metrics_vs <- function(pred, base) {
  x <- pred |>
    dplyr::select(row_1, row_2) |>
    dplyr::left_join(dplyr::select(base, row_1, base_row_2 = row_2), by = "row_1") |>
    dplyr::mutate(
      category = dplyr::case_when(
        is.na(base_row_2) ~ "extra",
        row_2 == base_row_2 ~ "correct",
        .default = "wrong_partner"
      )
    )
  n <- function(k) sum(x$category == k)

  tibble::tibble(
    predicted = nrow(x),
    base_links = nrow(base),
    correct = n("correct"),
    wrong_partner = n("wrong_partner"),
    extra = n("extra"),
    precision = correct / predicted,
    recall = correct / nrow(base)
  )
}
