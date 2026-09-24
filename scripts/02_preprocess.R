# 02_preprocess.R
# Clean linkage fields and derive name tokens.
#
# - date: onset date, carried through as a Date (not compared by the
#   model, kept for the audit; no cleaning needed)
# - sex: "Unknown" -> NA
# - age: implausible values (<0 or >110) -> NA
# - adm1-3: standardized free text (accents folded, case/punct normalized);
#   rare spelling variants of adm1 snapped to the frequent value
# - adm4_tokens: order-free set of village / quartier place-name tokens
#   (type words, house numbers dropped; see R/prep_adm.R); the raw adm4
#   text is dropped
# - name: standardized string + order-free token list (see R/prep_names.R)
# - phones: list-column of canonical phone numbers per record (see
#   R/prep_phone.R); the raw field is dropped
# - job_cats / job: set of standardized occupation categories per record
#   and its single primary category (see R/prep_job.R); the raw D1 text and
#   the raw D2 flag/detail columns are dropped
#
# Cross-dataset harmonization (after both datasets are cleaned):
# - adm2, adm3, adm4 tokens: spelling variants aligned across the datasets
#   (align_vocab() / align_tokens() in R/prep_adm.R): a D2 value absent
#   from D1's vocabulary is snapped to its nearest D1 value at Jaro-Winkler
#   >= ALIGN_THETA; a D1 value absent from D2's vocabulary likewise, but
#   only if carried by fewer than ALIGN_MAX_N D1 records (a frequent D1
#   value is a real place D2 has no cases from). Values present in both
#   vocabularies are never touched.
# - phones: numbers on more than PHONE_MAX_RECORDS records across both
#   datasets (facility / community lines) are dropped from the sets.
#
# The summary tables at the end hold aggregate counts and administrative-area
# names only (phone and name columns are protected and never printed).

source("R/utils.R")
source("R/prep_names.R")
source("R/prep_phone.R")
source("R/prep_job.R")
source("R/prep_adm.R")
suppressPackageStartupMessages(library(tidyverse))

options(pillar.width = Inf)
# options(pillar.width = Inf, pillar.print_max = Inf)

ALIGN_THETA <- 0.94
ALIGN_MAX_N <- 5L
PHONE_MAX_RECORDS <- 10L


## per-dataset cleaning --------------------------------------------------------
preprocess <- function(d) {
  d |>
    mutate(
      sex = if_else(sex %in% c("Male", "Female"), sex, NA_character_),
      age = if_else(age >= 0 & age <= 110, age, NA_integer_),
      across(c(adm1, adm2, adm3), std_text),
      adm1 = snap_rare_levels(adm1),
      adm4_tokens = adm4_tokens(adm4),
      name_clean = std_name(name),
      name_tokens = name_tokens(name),
      phones = phone_set(phone_raw)
    ) |>
    select(-phone_raw, -adm4)
}

# the cleaned datasets are the input of every later stage
pth <- paths()

d1 <- readRDS(pth$d1_harmonized) |>
  preprocess() |>
  mutate(job_cats = job_d1(job_raw), job = job_primary(job_cats)) |>
  select(-job_raw)

# D2 occupation comes from the flag / detail columns, dropped once mapped
d2_h <- readRDS(pth$d2_harmonized)

d2_nonjob_cols <- c("row", "name", "date", "age", "sex", "adm1", "adm2", "adm3", "adm4", "phone_raw")
d2_job_cols <- setdiff(names(d2_h), d2_nonjob_cols)

d2 <- d2_h |>
  preprocess() |>
  mutate(job_cats = job_d2(d2_h), job = job_primary(job_cats)) |>
  select(-all_of(d2_job_cols))

## cross-dataset harmonization -------------------------------------------------

# adm2 / adm3: D2 values snapped to D1's vocabulary, then rare D1 values to D2's
# TODOS: implement full geo-recoding routine, parent levels should factor into alignment
align_maps <- list()

for (v in c("adm2", "adm3")) {
  to_d1 <- align_vocab(d2[[v]], d1[[v]], theta = ALIGN_THETA)
  d2[[v]] <- to_d1$x

  to_d2 <- align_vocab(d1[[v]], d2[[v]], theta = ALIGN_THETA, max_n = ALIGN_MAX_N)
  d1[[v]] <- to_d2$x

  align_maps[[v]] <- bind_rows(`D2 -> D1` = to_d1$map, `rare D1 -> D2` = to_d2$map, .id = "direction")
}

# adm4 tokens: the same, over the token vocabulary
tok_to_d1 <- align_tokens(d2$adm4_tokens, d1$adm4_tokens, theta = ALIGN_THETA)
d2$adm4_tokens <- tok_to_d1$tokens

tok_to_d2 <- align_tokens(d1$adm4_tokens, d2$adm4_tokens, theta = ALIGN_THETA, max_n = ALIGN_MAX_N)
d1$adm4_tokens <- tok_to_d2$tokens

align_maps$adm4 <- bind_rows(`D2 -> D1` = tok_to_d1$map, `rare D1 -> D2` = tok_to_d2$map, .id = "direction")

# phones: drop numbers shared by too many records to identify anyone
ph <- phone_drop_shared(d1$phones, d2$phones, max_records = PHONE_MAX_RECORDS)
d1$phones <- ph$sets_1
d2$phones <- ph$sets_2

save_derived(d1, pth$d1)
save_derived(d2, pth$d2)


## summaries -------------------------------------------------------------------

# alignment: values replaced and records touched, per field and direction
align_replacements <- bind_rows(align_maps, .id = "field") |>
  as_tibble()

align_replacements |>
  summarise(values = n(), records = sum(n), .by = c(field, direction))

# the most frequent replacements (adm4 counts are record-tokens)
align_replacements |>
  slice_max(n, n = 15, by = field, with_ties = FALSE) |>
  arrange(field, direction, desc(n)) |>
  print(width = Inf, n = "all")

# phones dropped as shared lines
c(numbers_dropped = ph$n_dropped, records_affected = ph$n_records, max_records = PHONE_MAX_RECORDS)

# missingness of the cleaned fields
bind_rows(d1 = missingness(drop_protected(d1)), d2 = missingness(drop_protected(d2)), .id = "dataset") |>
  pivot_wider(id_cols = col, names_from = dataset, values_from = c(n_missing, pct_missing))

# vocabulary sizes and set-valued field coverage
field_summary <- function(d) {
  tibble(
    records = nrow(d),
    adm2_distinct = n_distinct(d$adm2, na.rm = TRUE),
    adm3_distinct = n_distinct(d$adm3, na.rm = TRUE),
    adm4_any_token = sum(lengths(d$adm4_tokens) >= 1),
    adm4_distinct_tokens = n_distinct(unlist(d$adm4_tokens)),
    phone_any = sum(lengths(d$phones) >= 1),
    phone_two_plus = sum(lengths(d$phones) >= 2),
    phone_max = max(lengths(d$phones))
  )
}

bind_rows(d1 = field_summary(d1), d2 = field_summary(d2), .id = "dataset") |>
  print(width = Inf, n = "all")

# primary occupation category
bind_rows(d1 = count(d1, job), d2 = count(d2, job), .id = "dataset") |>
  pivot_wider(names_from = dataset, values_from = n, values_fill = 0L) |>
  print(width = Inf, n = "all")
