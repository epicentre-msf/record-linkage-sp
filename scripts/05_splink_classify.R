# 05_splink_classify.R
# Classification of the pairs scored by Splink (splink/predict.py):
# two-threshold classification on the posterior and greedy one-to-one
# assignment (R/classify.R).
#
# Splink's match_weight is the log2 posterior odds, prior included. The
# prior term log2(lambda / (1 - lambda)) is removed here so that `score`
# is the log2 likelihood ratio of the pair alone, which does not depend
# on the prior and can be re-thresholded under another one
# (07_project_vaccination.R); `posterior` is Splink's match probability.
# The pair is oriented by source_dataset (either side may hold the D1
# record under link_only) to row_1 (D1) / row_2 (D2).
#
# Outputs, under data-derived/splink/ (paths() in R/paths.R): fit.rds
# (the fitted parameters, read_splink_fit() in R/splink_fit.R), scores.rds
# (row_1, row_2, score, posterior), links.rds (the pairs above the review
# threshold, ranked, with `selected` for the 1:1 assignment and `class`
# link / review) and run.json. The summaries below are aggregate counts
# only.

## packages and source ----------------------------------------------------------
suppressPackageStartupMessages(library(data.table))
suppressPackageStartupMessages(library(tidyverse))
library(arrow)
source("R/classify.R")
source("R/splink_fit.R")
source("R/utils.R")

options(pillar.width = Inf)

pth <- paths()

c(review = REVIEW, accept = ACCEPT)


## fitted parameters -------------------------------------------------------------

fit <- read_splink_fit(pth$splink_model)

c(lambda = signif(fit$lambda, 4), prior_bits = round(fit$prior_bits, 2))

fit$levels |>
  mutate(across(c(m, u), \(x) signif(x, 4)), weight = round(weight, 2))

save_derived(fit, pth$fit)


## scored pairs ------------------------------------------------------------------

pred <- read_parquet(pth$predictions) |>
  as.data.table()

c(candidate_pairs = nrow(pred))
stopifnot(all(pred$source_dataset_l != pred$source_dataset_r))

# orient to row_1 (D1) / row_2 (D2)
scored <- pred[, .(
  row_1 = fifelse(source_dataset_l == "d1", unique_id_l, unique_id_r),
  row_2 = fifelse(source_dataset_l == "d1", unique_id_r, unique_id_l),
  score = match_weight - fit$prior_bits,
  posterior = match_probability
)]
rm(pred)
invisible(gc())

stopifnot(!anyDuplicated(scored, by = c("row_1", "row_2")))

save_derived(scored, pth$scores)
write_run_info(lambda = fit$lambda, candidate_pairs = nrow(scored), splink_model = pth$splink_model)


## classify and assign ---------------------------------------------------------
cand <- scored[posterior >= REVIEW, .(row_1, row_2, score, posterior)] |>
  as_tibble() |>
  one_to_one() |>
  mutate(class = if_else(posterior >= ACCEPT, "link", "review"))

save_derived(cand, pth$links)


## summaries -------------------------------------------------------------------
c(
  scored_pairs = nrow(scored),
  above_review = nrow(cand),
  above_accept = sum(cand$class == "link")
)

# one-to-one assignment (descending score)
cand |>
  count(class, selected) |>
  arrange(class, desc(selected))

# multiplicity before assignment: records by number of candidates above REVIEW
bind_rows(
  d1 = count(cand, row_1, name = "candidates"),
  d2 = count(cand, row_2, name = "candidates"),
  .id = "dataset"
) |>
  count(dataset, candidates, name = "records")

# candidate pairs by 2-bit score bin (log2 LR), bar on a log scale
scored |>
  count(bin = 2 * floor(score / 2)) |>
  as_tibble() |>
  arrange(bin) |>
  mutate(bar = strrep("#", pmax(1, round(30 * log10(n) / max(log10(n)))))) |>
  print(n = "all")

# selected pairs: score and posterior summary
cand |>
  filter(selected) |>
  summarise(
    n = n(),
    score_min = round(min(score), 1),
    score_med = round(median(score), 1),
    score_max = round(max(score), 1),
    post_min = round(min(posterior), 3),
    post_max = round(max(posterior), 3)
  )
