# 06_evaluate.R
# Evaluation of the linkage against the reference linkage.
#
# Together with 07_project_vaccination.R and 08_plots.R this is the only
# place that touches data-derived/reference.rds (through R/evaluate.R,
# which defines the prediction categories and metrics). Reference facts:
# 2,290 D1 records are confirmed cases (order_d1 non-missing), all
# expected to be in D2; previous work linked 2,207 of them (id_d2 in D1).
# The reference is read only here, after the pipeline is frozen: nothing
# in it feeds back into the model.
#
#   1  disposition of the reference pairs: reached by the blocking, score
#      band, selected by the 1:1 assignment
#   2  prediction categories and metrics at the two operating points
#      (output/splink/eval_reference.csv)
#   3  the comparison levels of the reference pairs that were reached but
#      not linked (output/splink/eval_missed_levels.csv)
#
# All tables are aggregate counts/metrics -- no protected values.

## packages and source ----------------------------------------------------------
suppressPackageStartupMessages(library(tidyverse))
library(arrow)
source("R/classify.R") # ACCEPT / REVIEW
source("R/evaluate.R")
source("R/splink_fit.R")
source("R/utils.R")

options(pillar.width = Inf)

pth <- paths()
dir.create(pth$out_dir, showWarnings = FALSE, recursive = TRUE)

truth <- reference_pairs(readRDS(pth$reference))
scores <- readRDS(pth$scores)
links <- readRDS(pth$links)
fit <- readRDS(pth$fit)

c(
  reference_pairs = nrow(truth$pairs),
  confirmed_d1 = length(truth$confirmed),
  unverifiable = length(truth$unverifiable)
)


## 1 disposition of the reference pairs ------------------------------------------

# each reference pair: reached by the blocking (i.e. scored)? score /
# posterior if so, and selected by the assignment?
ref_pairs <- truth$pairs |>
  left_join(scores, by = c("row_1", "row_2")) |>
  left_join(links |> filter(selected) |> select(row_1, row_2) |> mutate(selected = TRUE), by = c("row_1", "row_2")) |>
  mutate(
    in_block = !is.na(score),
    selected = coalesce(selected, FALSE),
    band = cut(posterior, c(-Inf, REVIEW, ACCEPT, Inf), labels = c("<0.5", "0.5-0.9", ">=0.9"))
  )

# blocking recall
ref_pairs |>
  summarise(reference_pairs = n(), n_in_block = sum(in_block), pct = round(100 * n_in_block / reference_pairs, 2))

ref_pairs |>
  count(in_block, band, selected) |>
  arrange(in_block, band)


## 2 prediction categories at the two operating points -------------------------

ops <- list(
  "links only (posterior >= 0.9, 1:1)" = links |> filter(selected, class == "link"),
  "links + review (posterior >= 0.5, 1:1)" = links |> filter(selected)
)

tab_ref <- map(ops, metrics_ref, truth = truth) |>
  list_rbind(names_to = "operating_point") |>
  mutate(across(c(precision_known, precision_lo, precision_hi, recall_known), \(x) round(x, 4)))

tab_ref |>
  select(-precision_lo, -precision_hi)

write_csv(tab_ref, file.path(pth$out_dir, "eval_reference.csv"))


## 3 why were reference pairs missed? --------------------------------------------

# the comparison levels of the reference pairs that were scored but not
# selected, recovered from the per-comparison Bayes factors that the
# predictions carry (level_from_bf() in R/splink_fit.R)
missed <- ref_pairs |>
  filter(in_block, !selected) |>
  select(row_1, row_2)

c(missed_scored = nrow(missed))

# only the pairs whose D1 record is a missed one are read from the parquet
missed_pred <- open_dataset(pth$predictions) |>
  filter(
    (source_dataset_l == "d1" & unique_id_l %in% missed$row_1) |
      (source_dataset_r == "d1" & unique_id_r %in% missed$row_1)
  ) |>
  collect() |>
  mutate(
    row_1 = if_else(source_dataset_l == "d1", unique_id_l, unique_id_r),
    row_2 = if_else(source_dataset_l == "d1", unique_id_r, unique_id_l)
  ) |>
  semi_join(missed, by = c("row_1", "row_2"))

stopifnot(nrow(missed_pred) == nrow(missed))

variables <- unique(fit$levels$variable)

missed_levels <- missed_pred |>
  transmute(
    row_1,
    row_2,
    !!!set_names(map(variables, \(v) level_from_bf(missed_pred[[paste0("bf_", v)]], fit, v)), variables)
  ) |>
  pivot_longer(all_of(variables), names_to = "variable", values_to = "level") |>
  count(variable, level) |>
  mutate(variable = factor(variable, levels = variables)) |>
  arrange(variable, desc(n))

missed_levels |> print(n = "all")

write_csv(missed_levels, file.path(pth$out_dir, "eval_missed_levels.csv"))
