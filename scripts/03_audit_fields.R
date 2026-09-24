# 03_audit_fields.R
# Aggregate audit of the cleaned phone, occupation and administrative-area
# fields produced by 02_preprocess.R, and of the two D2 admin hierarchies
# behind the choice made in 01_ingest.R. All tables are counts only; phone
# values are never printed. Writes the occupation mapping tables (raw text
# -> categories, with counts) to output/ for manual review -- occupation
# text is not a protected field.

source("R/utils.R")
source("R/prep_phone.R")
source("R/prep_job.R")
source("R/prep_adm.R")
suppressPackageStartupMessages(library(tidyverse))

options(pillar.width = Inf)

pth <- paths()

d1 <- readRDS(pth$d1)
d2 <- readRDS(pth$d2)
d1_h <- readRDS(pth$d1_harmonized)
d2_h <- readRDS(pth$d2_harmonized)
dir.create("output", showWarnings = FALSE)


## phones: yield and sharing ---------------------------------------------------
phone_yield <- function(d, d_h) {
  n_ph <- lengths(d$phones)
  tibble(
    raw_non_missing = sum(!is.na(d_h$phone_raw)),
    one_plus = sum(n_ph >= 1),
    two_plus = sum(n_ph >= 2),
    raw_but_no_number = sum(!is.na(d_h$phone_raw) & n_ph == 0)
  )
}

bind_rows(
  d1 = phone_yield(d1, d1_h),
  d2 = phone_yield(d2, d2_h),
  .id = "dataset"
)

# digits per canonical number
digits <- function(d) count(tibble(digits = nchar(unlist(d$phones))), digits)

bind_rows(d1 = digits(d1), d2 = digits(d2), .id = "dataset") |>
  pivot_wider(names_from = dataset, values_from = n, values_fill = 0L)

# numbers by the count of records sharing them (first entries)
numbers_by_sharing <- function(d) {
  tibble(number = unlist(d$phones)) |>
    count(number, name = "records") |>
    count(records, name = "numbers")
}

bind_rows(d1 = numbers_by_sharing(d1), d2 = numbers_by_sharing(d2), .id = "dataset") |>
  pivot_wider(names_from = dataset, values_from = numbers, values_fill = 0L) |>
  slice_head(n = 8)

# distinct numbers, and D2 records reachable through a shared number
p1 <- unique(unlist(d1$phones))
p2 <- unique(unlist(d2$phones))

tibble(
  distinct_d1 = length(p1),
  distinct_d2 = length(p2),
  in_both = length(intersect(p1, p2)),
  d2_records_with_number = sum(lengths(d2$phones) > 0),
  d2_records_sharing_with_d1 = sum(map_lgl(d2$phones, \(p) any(p %in% p1)))
)


## jobs: category distributions ------------------------------------------------

# primary job category
bind_rows(d1 = count(d1, job), d2 = count(d2, job), .id = "dataset") |>
  mutate(pct = round(100 * n / sum(n), 1), .by = dataset) |>
  pivot_wider(names_from = dataset, values_from = c(n, pct), values_fill = 0) |>
  arrange(desc(n_d1))

# job categories per record
categories_per_record <- function(d) count(tibble(categories = lengths(d$job_cats)), categories)

bind_rows(d1 = categories_per_record(d1), d2 = categories_per_record(d2), .id = "dataset") |>
  pivot_wider(names_from = dataset, values_from = n, values_fill = 0L)

# category membership (records carrying each category)
category_members <- function(d) count(tibble(category = unlist(d$job_cats)), category)

bind_rows(d1 = category_members(d1), d2 = category_members(d2), .id = "dataset") |>
  pivot_wider(names_from = dataset, values_from = n, values_fill = 0L) |>
  arrange(desc(d1))


## job mapping tables for review: raw text -> categories -----------------------
map_d1 <- d1_h |>
  mutate(cats = job_string(job_d1(job_raw)), std = std_job_text(job_raw)) |>
  count(job_raw, std, cats, sort = TRUE)

map_d2 <- d2_h |>
  mutate(
    flags = apply(across(all_of(names(JOB_D2_FLAGS))), 1, \(r) paste(names(r)[r %in% TRUE], collapse = "+")),
    detail = other_occup_detail,
    cats = job_string(job_d2(d2_h)),
    across(c(flags, detail), ~ stringi::stri_trans_general(.x, "Latin-ASCII"))
  ) |>
  count(flags, other_occup, detail, cats, sort = TRUE)

qxl::qxl(map_d1, "output/job_mapping_d1.xlsx")
qxl::qxl(map_d2, "output/job_mapping_d2.xlsx")

# raw values that end up in "other" (unrecognized or explicit)
tibble(
  dataset = c("d1", "d2"),
  distinct_values = c(sum(map_d1$cats == "other", na.rm = TRUE), sum(map_d2$cats == "other", na.rm = TRUE)),
  records = c(sum(map_d1$n[map_d1$cats %in% "other"]), sum(map_d2$n[map_d2$cats %in% "other"]))
)


## administrative areas: the two D2 hierarchies, and the village field ---------

# D2 has adm1-3 from the line list (adm[1-3]_d2) and adm1-4 joined from an
# independent source (adm[1-4]_v_d2); 01_ingest.R uses the joined
# hierarchy. The checks below are reference-free: D1's own village ->
# health-area map (majority adm3 of each cleaned D1 village with >= 3
# records and >= 80% agreement) is used to ask which D2 source the village
# is consistent with where the two disagree.
d2_raw <- readRDS("data-raw/d2.rds")

jw_sim <- function(a, b) 1 - stringdist::stringdist(a, b, method = "jw", p = 0.1)

# native (a*) and joined (v*) values, cleaned the same way
src <- tibble(
  a1 = std_text(d2_raw$adm1_d2),
  v1 = snap_rare_levels(std_text(d2_raw$adm1_v_d2)),
  a2 = std_text(d2_raw$adm2_d2),
  v2 = std_text(d2_raw$adm2_v_d2),
  a3 = std_text(d2_raw$adm3_d2),
  v3 = std_text(d2_raw$adm3_v_d2),
  adm4 = adm4_std(d2_raw$adm4_v_d2)
)

# native vs joined agreement per level
map(
  1:3,
  \(lv) {
    a <- src[[paste0("a", lv)]]
    v <- src[[paste0("v", lv)]]
    jw <- jw_sim(a, v)
    tibble(
      level = paste0("adm", lv),
      agree = sum(a == v, na.rm = TRUE),
      spelling_variant = sum(a != v & jw >= 0.85, na.rm = TRUE), # JW >= 0.85
      different = sum(a != v & jw < 0.85, na.rm = TRUE),
      either_missing = sum(is.na(a) | is.na(v)),
      joined_missing = sum(is.na(v))
    )
  }
) |>
  list_rbind()

# D1's village -> dominant admin level map
vill_map <- function(level_d1) {
  tibble(adm4 = adm4_std(d1_h$adm4), lvl = std_text(level_d1)) |>
    filter(!is.na(adm4), !is.na(lvl)) |>
    count(adm4, lvl) |>
    mutate(tot = sum(n), share = n / tot, .by = adm4) |>
    slice_max(n, n = 1, by = adm4, with_ties = FALSE) |>
    filter(tot >= 3, share >= 0.8) |>
    select(adm4, lvl)
}

# where native and joined differ, which one does the village agree with?
map(
  2:3,
  \(lv) {
    x <- src |>
      inner_join(vill_map(d1_h[[paste0("adm", lv)]]), by = "adm4") |>
      rename(a = paste0("a", lv), v = paste0("v", lv)) |>
      filter(!is.na(a), !is.na(v), a != v, jw_sim(a, v) < 0.85)

    tibble(
      level = paste0("adm", lv),
      records = nrow(x),
      village_agrees_native = sum(x$lvl == x$a),
      village_agrees_joined = sum(x$lvl == x$v),
      neither = sum(x$lvl != x$a & x$lvl != x$v)
    )
  }
) |>
  list_rbind()

# village (adm4) tokens after cleaning
token_yield <- function(d, d_h) {
  tibble(
    raw_non_missing = sum(!is.na(d_h$adm4)),
    one_plus = sum(lengths(d$adm4_tokens) >= 1),
    two_plus = sum(lengths(d$adm4_tokens) >= 2),
    distinct_tokens = n_distinct(unlist(d$adm4_tokens))
  )
}

bind_rows(d1 = token_yield(d1, d1_h), d2 = token_yield(d2, d2_h), .id = "dataset")

tok1 <- unique(unlist(d1$adm4_tokens))

c(
  d2_records_with_token = sum(lengths(d2$adm4_tokens) > 0),
  d2_records_sharing_token_with_d1 = sum(map_lgl(d2$adm4_tokens, \(t) any(t %in% tok1)))
)

# most frequent tokens
bind_rows(
  d1 = count(tibble(token = unlist(d1$adm4_tokens)), token, sort = TRUE) |> slice_head(n = 15),
  d2 = count(tibble(token = unlist(d2$adm4_tokens)), token, sort = TRUE) |> slice_head(n = 15),
  .id = "dataset"
) |>
  print(n = "all")
