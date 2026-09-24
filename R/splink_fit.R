# The fitted Splink model (splink/model.json) read into R: the prior and
# one row per (comparison, level) with m, u and the match weight in bits,
# in the order of the model. Used by scripts/05_splink_classify.R (which
# saves the table beside the scores), 06_evaluate.R (recovering the
# comparison levels of a scored pair from its Bayes factors) and
# 08_plots.R. The JSON holds settings and parameters only, nothing from
# the records.
#
# Requires: jsonlite, purrr, tibble, dplyr.

read_splink_fit <- function(path = paths()$splink_model) {
  model <- jsonlite::read_json(path)
  lambda <- model$probability_two_random_records_match

  # the null level ("missing": either side empty) has weight 0 by
  # construction and is left out
  levels <- purrr::map(model$comparisons, \(cmp) {
    lv <- purrr::keep(cmp$comparison_levels, \(l) !isTRUE(l$is_null_level))
    tibble::tibble(
      variable = cmp$output_column_name,
      level = purrr::map_chr(lv, \(l) l$label_for_charts %||% l$sql_condition),
      m = purrr::map_dbl(lv, \(l) l$m_probability),
      u = purrr::map_dbl(lv, \(l) l$u_probability),
      tf_adjusted = purrr::map_lgl(lv, \(l) !is.null(l$tf_adjustment_column))
    )
  }) |>
    purrr::list_rbind() |>
    dplyr::mutate(weight = log2(m / u))

  list(
    lambda = lambda,
    prior_bits = log2(lambda / (1 - lambda)),
    levels = levels
  )
}

# The comparison level behind a Bayes factor. The predictions hold, per
# comparison, the Bayes factor m/u of the level the pair fell in (exactly
# 1 for the null level, a missing value on either side) rather than the
# level itself, because Splink's comparison-vector columns come only with
# the record values, which the predictions leave out. Every level has its
# own m/u, so the level is recovered as the one whose weight is nearest to
# log2 of the Bayes factor. For a term-frequency adjusted comparison the
# adjustment is a separate column and the base factor still names the
# level.
level_from_bf <- function(bf, fit, variable) {
  lv <- fit$levels[fit$levels$variable == variable, ]
  bits <- log2(bf)
  nearest <- vapply(
    bits,
    \(b) if (is.na(b)) NA_character_ else lv$level[which.min(abs(lv$weight - b))],
    character(1)
  )
  ifelse(bf == 1, "missing", nearest)
}
