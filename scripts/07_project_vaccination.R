# 07_project_vaccination.R
# Projection of the evaluation to the setting of the future vaccination
# linkage, and the sensitivity of the current evaluation to the fixed
# prior.
#
# The score of a pair is its log2 likelihood ratio, independent of the
# prior, so the same scored pairs can be re-thresholded under any prior:
# posterior = 1 / (1 + 2^-(score + log2(lambda / (1 - lambda)))). The
# vaccination linkage (about 300,000 vaccination records against 15,000
# surveillance records, of which about 10% are expected to have a
# vaccination record: 1,500 matches among 4.5 billion pairs) has a prior
# some 30 times lower than D1 x D2 (2,300 among 209 million), so a pair
# needs about 5 bits more evidence for the same posterior. Under that
# prior the links found here are counted against the reference and
# projected to the future counts under two assumptions, stated as such:
#
#   * the m- and u-probabilities transfer, so that the share of matches
#     above a likelihood-ratio threshold (recall) and the rate of
#     non-match pairs above it are the same there as here;
#   * hence the correct and wrong-partner counts scale with the number of
#     matches and the false positives with the number of non-match pairs.
#
# Both are optimistic in the one respect that matters most: the future
# age will be recorded years apart (the age comparison's offset absorbs
# the expected gap, not the noise), and the future name and address
# quality is unknown. The projection is what the D1 x D2 evidence implies
# for the future setting, not a forecast.
#
#   1  the priors: current, future, and the future one three times higher
#      and lower (the linkage will not know its overlap to better than that)
#   2  per prior: links at the two operating points, counted against the
#      reference and projected (output/splink/projection.csv)
#   3  precision / recall across the posterior threshold under the current
#      and the future prior (output/splink/projection_pr.png)
#   4  prior sensitivity in the current setting: the same pairs
#      re-thresholded under a prior three times higher or lower
#      (output/splink/projection_sensitivity.csv)
#
# Rscript scripts/07_project_vaccination.R [--n1=300000 --n2=15000 --matches=1500]
#
# Reporting only: reads the reference, writes aggregates (no protected
# values or row keys).

## packages and source ----------------------------------------------------------
suppressPackageStartupMessages(library(tidyverse))
source("R/classify.R") # ACCEPT / REVIEW, one_to_one()
source("R/evaluate.R")
source("R/utils.R")

options(pillar.width = Inf)

pth <- paths()
dir.create(pth$out_dir, showWarnings = FALSE, recursive = TRUE)

# doubles: the product of the two sizes overflows an integer
future <- list(
  n1 = cli_arg("n1", 3e5),
  n2 = cli_arg("n2", 15e3),
  matches = cli_arg("matches", 15e3 * 0.1)
)

truth <- reference_pairs(readRDS(pth$reference))

n1_now <- nrow(readRDS(pth$d1))
n2_now <- nrow(readRDS(pth$d2))


## 1 the priors ----------------------------------------------------------------

# the fixed prior of the fitted model
lambda_now <- readRDS(pth$fit)$lambda
matches_now <- lambda_now * n1_now * n2_now

lambda_future <- future$matches / (future$n1 * future$n2)

prior_bits <- function(lambda) log2(lambda / (1 - lambda))

# scaling of the counted links to the future: matches and non-match pairs
scale_matches <- future$matches / matches_now
scale_nonmatch <- (future$n1 * future$n2 - future$matches) / (n1_now * n2_now - matches_now)

priors <- tibble(
  prior = c("current", "future / 3", "future", "future x 3"),
  lambda = c(lambda_now, lambda_future / 3, lambda_future, lambda_future * 3)
) |>
  mutate(
    prior_bits = round(prior_bits(lambda), 2),
    bits_for_review = round(-prior_bits(lambda), 2),
    bits_for_link = round(log2(ACCEPT / (1 - ACCEPT)) - prior_bits(lambda), 2)
  )

priors

c(
  matches_now = round(matches_now),
  matches_future = future$matches,
  scale_matches = signif(scale_matches, 3),
  scale_nonmatch = signif(scale_nonmatch, 3)
)


## scored pairs ----------------------------------------------------------------

# only pairs that can reach the review threshold under the highest prior
# considered (three times the current one, section 4) are kept
score_min <- -prior_bits(3 * lambda_now) - 1

hi <- readRDS(pth$scores) |>
  filter(score >= score_min) |>
  as_tibble() |>
  select(row_1, row_2, score)
invisible(gc())

c(pairs_kept = nrow(hi))

# links under one prior at one threshold, counted against the reference
links_under <- function(lambda, thr) {
  hi |>
    mutate(posterior = 1 / (1 + 2^-(score + prior_bits(lambda)))) |>
    filter(posterior >= thr) |>
    one_to_one() |>
    filter(selected) |>
    metrics_ref(truth) |>
    select(predicted, correct, wrong_partner, unverifiable, false_positive, recall = recall_known)
}

# the projected counts and precision (unverifiable links excluded from the
# precision denominator, as in 06_evaluate.R)
project <- function(counts) {
  counts |>
    mutate(
      correct_proj = correct * scale_matches,
      wrong_partner_proj = wrong_partner * scale_matches,
      false_positive_proj = false_positive * scale_nonmatch,
      links_proj = correct_proj + wrong_partner_proj + false_positive_proj,
      precision_now = correct / (predicted - unverifiable),
      precision_proj = correct_proj / links_proj
    )
}


## 2 links by prior at the two operating points --------------------------------

ops <- c(link = ACCEPT, review = REVIEW)

tab <- expand_grid(priors, operating_point = names(ops)) |>
  mutate(counts = map2(lambda, operating_point, \(l, op) links_under(l, ops[[op]]))) |>
  unnest(counts) |>
  project() |>
  mutate(
    across(c(correct_proj, wrong_partner_proj, false_positive_proj, links_proj), \(x) round(x, 1)),
    across(c(recall, precision_now, precision_proj), \(x) round(x, 4))
  ) |>
  select(
    prior,
    lambda,
    operating_point,
    predicted,
    correct,
    wrong_partner,
    unverifiable,
    false_positive,
    precision_now,
    recall,
    correct_proj,
    false_positive_proj,
    links_proj,
    precision_proj
  )

# the current setting, as in 06_evaluate.R
tab |>
  filter(prior == "current") |>
  select(operating_point, predicted, correct, false_positive, precision_now, recall)

# the future prior: what the same model would link there, and how well
tab |>
  filter(prior != "current") |>
  select(
    prior,
    operating_point,
    correct,
    false_positive,
    recall,
    correct_proj,
    false_positive_proj,
    links_proj,
    precision_proj
  )

write_csv(tab, file.path(pth$out_dir, "projection.csv"))


## 3 precision / recall across the threshold, current and future prior ---------

thr <- round(seq(0.05, 0.99, by = 0.01), 2)

sweep <- expand_grid(prior = c("current", "future"), thr = thr) |>
  mutate(lambda = if_else(prior == "current", lambda_now, lambda_future)) |>
  mutate(counts = map2(lambda, thr, links_under)) |>
  unnest(counts) |>
  project() |>
  mutate(precision = if_else(prior == "current", precision_now, precision_proj))

prior_labels <- c(
  current = sprintf(
    "D1 x D2 as observed (%s matches in %.3g pairs)",
    format(round(matches_now), big.mark = ","),
    n1_now * n2_now
  ),
  future = sprintf(
    "projected to the vaccination setting (%s matches in %.3g pairs)",
    format(future$matches, big.mark = ","),
    future$n1 * future$n2
  )
)

sweep_plot <- sweep |>
  filter(!is.na(precision)) |>
  mutate(prior = factor(prior, levels = names(prior_labels)))

p_pr <- ggplot(sweep_plot, aes(recall, precision, colour = prior)) +
  geom_path(linewidth = 0.8) +
  geom_point(
    data = filter(sweep_plot, thr %in% c(REVIEW, ACCEPT)),
    aes(fill = prior),
    shape = 21,
    colour = "white",
    size = 2.6,
    stroke = 0.8
  ) +
  scale_colour_manual(
    values = c(current = "#2166ac", future = "#b2182b"),
    labels = prior_labels,
    name = NULL,
    aesthetics = c("colour", "fill")
  ) +
  scale_x_continuous(labels = scales::percent, limits = c(0, 1)) +
  scale_y_continuous(labels = scales::percent, limits = c(0, 1)) +
  labs(
    x = "Recall",
    y = "Precision",
    subtitle = "Points: the review (0.5) and link (0.9) posterior thresholds, 1:1 assignment"
  ) +
  theme_minimal(base_size = 11) +
  theme(
    legend.position = "bottom",
    legend.direction = "vertical",
    panel.grid.minor = element_blank(),
    axis.title.x = element_text(margin = margin(t = 5)),
    axis.title.y = element_text(margin = margin(r = 4))
  )

graphics.off()
quartz(height = 6, width = 6, dpi = 130)
print(p_pr)

if (FALSE) {
  ggsave(
    file.path(pth$out_dir, "projection_pr.png"),
    p_pr,
    height = 6,
    width = 6,
    dpi = 400
  )
}

# recall at a few projected precisions: what the future linkage could
# deliver at a given purity if the parameters transfer
sweep |>
  filter(prior == "future") |>
  summarise(
    recall_at_p90 = round(max(c(recall[precision_proj >= 0.9], 0)), 3),
    recall_at_p80 = round(max(c(recall[precision_proj >= 0.8], 0)), 3),
    recall_at_p50 = round(max(c(recall[precision_proj >= 0.5], 0)), 3)
  )


## 4 prior sensitivity in the current setting ----------------------------------

# the same pairs re-thresholded under a prior three times higher or lower:
# how much the current evaluation depends on the fixed 2,300
sens <- expand_grid(factor = c(1 / 3, 1, 3), operating_point = names(ops)) |>
  mutate(
    lambda = lambda_now * factor,
    counts = map2(lambda, operating_point, \(l, op) links_under(l, ops[[op]]))
  ) |>
  unnest(counts) |>
  mutate(
    precision = round(correct / (predicted - unverifiable), 4),
    recall = round(recall, 4),
    prior_factor = round(factor, 3)
  ) |>
  select(prior_factor, operating_point, predicted, correct, false_positive, precision, recall)

sens

write_csv(sens, file.path(pth$out_dir, "projection_sensitivity.csv"))
