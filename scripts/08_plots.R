# 08_plots.R
# Figures: the fitted match weights, and precision / recall against the
# reference across the posterior threshold.
#
#   1  the match weights of the fitted model, a static version of Splink's
#      match_weights.html chart (output/splink/match_weights.png)
#   2  precision / recall across the posterior threshold, 1:1 assignment,
#      with the review and link operating points marked
#      (output/splink/eval_pr.png)
#
# Section 2 reads the reference linkage; like 06_evaluate.R this is
# reporting only, and nothing here prints protected values or row keys.
# Run block by block: each plot ends with a quartz() block and a disabled
# ggsave() block.

## packages and source ----------------------------------------------------------
suppressPackageStartupMessages(library(tidyverse))
source("R/classify.R") # ACCEPT / REVIEW, one_to_one()
source("R/evaluate.R")
source("R/utils.R")

options(pillar.width = Inf)

pth <- paths()
dir.create(pth$out_dir, showWarnings = FALSE, recursive = TRUE)

fit <- readRDS(pth$fit)


## 1 match weights ---------------------------------------------------------------
# One panel per comparison, one bar per level (most agreeing at the top),
# bar length and fill the match weight in bits; the prior (starting) match
# weight log2(lambda / (1 - lambda)) as its own panel, as in the Splink
# chart. The fill mirrors the x axis, so no legend.

variable_labels <- c(
  prior = "prior",
  name = "name",
  age = "age (years)",
  sex = "sex",
  geo = "geography",
  job = "job",
  phone = "phone"
)

# the name levels are split by the surprisal of the tokens the pair shares
# (splink/comparisons.py); "agree" alone is the plain level of the other
# fields, so the name labels apply to the name comparison only
name_labels <- c(
  agree_bits20 = "agree, ≥ 20 bits shared",
  agree_bits12 = "agree, 12-20 bits shared",
  agree = "agree, < 12 bits shared",
  strong_bits20 = "strong, ≥ 20 bits shared",
  strong_bits12 = "strong, 12-20 bits shared",
  strong = "strong, < 12 bits shared",
  weak_bits12 = "weak, ≥ 12 bits shared",
  weak = "weak, < 12 bits shared"
)

geo_labels <- c(
  adm4 = "village",
  adm3 = "health area",
  adm2 = "health zone",
  adm1 = "province",
  different = "different province"
)

weights <- fit$levels |>
  select(variable, level, weight) |>
  add_row(variable = "prior", level = "two random records", weight = fit$prior_bits, .before = 1) |>
  mutate(
    level = case_when(
      variable == "name" ~ coalesce(name_labels[level], level),
      variable == "geo" ~ geo_labels[level],
      .default = level
    ),
    variable = factor(variable_labels[variable], levels = variable_labels),
    # levels repeat across variables (agree / disagree), so the y position
    # is the row itself, labelled with the level
    key = fct_rev(fct_inorder(paste(variable, level, sep = " / ")))
  )

p_mw <- ggplot(weights, aes(weight, key, fill = weight)) +
  # the outline keeps the near-zero bars visible against the pale midpoint
  geom_col(width = 0.75, colour = "grey70", linewidth = 0.2) +
  geom_vline(xintercept = 0, colour = "grey60") +
  geom_text(
    aes(
      label = formatC(weight, format = "f", digits = 1),
      hjust = if_else(weight >= 0, -0.25, 1.25)
    ),
    size = 2.6,
    colour = "grey30"
  ) +
  facet_grid(variable ~ ., scales = "free_y", space = "free_y", switch = "y") +
  scale_fill_gradient2(
    low = "#d73027",
    mid = "#ffffbf",
    high = "#1a9850",
    midpoint = 0,
    guide = "none"
  ) +
  scale_x_continuous(expand = expansion(mult = 0.12)) +
  scale_y_discrete(labels = \(k) set_names(weights$level, weights$key)[k]) +
  labs(
    x = "Match weight (bits), log2(m/u)",
    y = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(
    strip.placement = "outside",
    strip.text.y.left = element_text(angle = 0, hjust = 1, face = "bold"),
    panel.grid.major.y = element_blank(),
    panel.grid.minor = element_blank(),
    panel.spacing.y = unit(0.4, "lines"),
    axis.title.x = element_text(margin = margin(t = 5))
  )

graphics.off()
quartz(height = 6, width = 7.5, dpi = 130)
print(p_mw)

if (FALSE) {
  ggsave(
    file.path(pth$out_dir, "match_weights.png"),
    p_mw,
    height = 6,
    width = 7.5,
    dpi = 400
  )
}


## 2 precision / recall across the threshold -----------------------------------

truth <- reference_pairs(readRDS(pth$reference))

# pairs that can reach the review threshold under any 1:1 assignment
hi <- readRDS(pth$scores) |>
  filter(posterior >= 0.02) |>
  as_tibble()
invisible(gc())

thr <- round(seq(0.05, 0.99, by = 0.01), 2)

sweep <- map(thr, \(t) {
  hi |>
    filter(posterior >= t) |>
    one_to_one() |>
    filter(selected) |>
    metrics_ref(truth) |>
    transmute(thr = t, precision = precision_known, recall = recall_known)
}) |>
  list_rbind()

ops <- sweep |>
  filter(thr %in% c(REVIEW, ACCEPT)) |>
  mutate(label = if_else(thr == ACCEPT, "link (0.9)", "review (0.5)"))

p_pr <- ggplot(sweep, aes(recall, precision)) +
  geom_path(linewidth = 0.8, colour = "#2166ac") +
  geom_point(data = ops, shape = 21, fill = "#2166ac", colour = "white", size = 2.8, stroke = 0.8) +
  geom_text(data = ops, aes(label = label), hjust = -0.15, vjust = 1.3, size = 3, colour = "grey30") +
  scale_x_continuous(labels = scales::percent) +
  scale_y_continuous(labels = scales::percent) +
  # recall below 60 % is reached only at the very top of the threshold range
  coord_cartesian(xlim = c(0.6, 1)) +
  labs(
    x = "Recall\n(% of reference pairs that are linked)",
    y = "Precision\n(% of verifiable links that are correct)",
    subtitle = "Posterior threshold from 0.05 to 0.99, 1:1 assignment"
  ) +
  theme_minimal(base_size = 11.5) +
  theme(
    panel.grid.minor = element_blank(),
    axis.title.x = element_text(margin = margin(t = 5)),
    axis.title.y = element_text(margin = margin(r = 4))
  )

graphics.off()
quartz(height = 5, width = 6, dpi = 140)
print(p_pr)

if (FALSE) {
  ggsave(
    file.path(pth$out_dir, "eval_pr.png"),
    p_pr,
    height = 5,
    width = 6,
    dpi = 400
  )
}
