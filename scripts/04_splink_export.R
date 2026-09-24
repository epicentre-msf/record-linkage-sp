# 04_splink_export.R
# Export the cleaned datasets for Splink (splink/*.py): one parquet file
# per dataset with the fields the comparisons and blocking rules need.
# Splink reads both through DuckDB, and parquet list columns become DuckDB
# lists, which is what the token-set comparisons use.
#
# Two derived columns are computed here:
#
# - block_tokens, the keys of the shared-token blocking pass: a record's
#   full (length >= 2) name tokens minus the stop tokens, the tokens on
#   more than TOKEN_MAX_SHARE of either dataset's records, which would
#   pair almost everyone with almost everyone.
# - tf_tokens / tf_bits, the input of the name comparison's shared
#   surprisal levels (splink/comparisons.py): the record's distinct full
#   tokens and the pooled smoothed surprisal of each (token_surprisal() in
#   R/token_surprisal.R), aligned element by element. A pair's shared
#   surprisal is the sum of tf_bits over the tokens both records hold,
#   computed in SQL.
#
# name_key (the sorted full tokens as one string) is the blocking key of
# the first EM training block (splink/model.py). Empty token sets are
# written as NULL, not as empty lists, so that the Splink null levels apply
# and the record contributes no evidence on that field.
#
# Output: data-derived/splink/d1.parquet, d2.parquet. The files carry name
# tokens and phone numbers: protected values, never to be printed or
# previewed. The checks below are row counts, column types and
# missingness only.

## packages and source ----------------------------------------------------------
suppressPackageStartupMessages(library(tidyverse))
library(arrow)
source("R/prep_job.R") # JOB_IGNORE
source("R/token_surprisal.R") # token_long(), token_surprisal()
source("R/utils.R")

options(pillar.width = Inf)

TOKEN_MAX_SHARE <- 0.05

pth <- paths()

d1 <- readRDS(pth$d1)
d2 <- readRDS(pth$d2)


## blocking stop tokens ---------------------------------------------------------

# full (length >= 2) tokens, one row per (record, token)
full_tokens <- function(d) {
  tibble(row = rep(d$row, lengths(d$name_tokens)), token = unlist(d$name_tokens)) |>
    filter(nchar(token) >= 2L) |>
    distinct()
}

stop_tokens <- union(
  full_tokens(d1) |> count(token) |> filter(n > TOKEN_MAX_SHARE * nrow(d1)) |> pull(token),
  full_tokens(d2) |> count(token) |> filter(n > TOKEN_MAX_SHARE * nrow(d2)) |> pull(token)
)

c(stop_tokens = length(stop_tokens))


## token surprisal ---------------------------------------------------------------

# pooled smoothed surprisal per full token; one lookup for both datasets
tf <- token_surprisal(token_long(d1), token_long(d2), nrow(d1) + nrow(d2))
surprisal_of <- setNames(tf$s, tf$token)

# aggregate shape of the vocabulary (no token values)
tibble(
  tokens = nrow(tf),
  singletons = sum(tf$n == 1L),
  bits_max = round(max(tf$s), 2),
  bits_median = round(median(tf$s), 2),
  bits_min = round(min(tf$s), 2)
)


## export one dataset -----------------------------------------------------------

# an empty set becomes a NULL list element, which arrow writes as a null
null_if_empty <- function(x) {
  map(x, \(v) if (length(v) == 0L) NULL else v)
}

export_splink <- function(d, source) {
  d |>
    transmute(
      unique_id = row,
      source_dataset = source,
      name_tokens = null_if_empty(name_tokens),
      block_tokens = null_if_empty(map(name_tokens, \(t) setdiff(t[nchar(t) >= 2L], stop_tokens))),
      tf_tokens = null_if_empty(map(name_tokens, \(t) unique(t[nchar(t) >= 2L]))),
      tf_bits = null_if_empty(map(name_tokens, \(t) unname(surprisal_of[unique(t[nchar(t) >= 2L])]))),
      name_key = map_chr(name_tokens, \(t) {
        t <- t[nchar(t) >= 2L]
        if (length(t) == 0L) NA_character_ else paste(sort(t), collapse = " ")
      }),
      date,
      age,
      sex,
      adm1,
      adm2,
      adm3,
      adm4_tokens = null_if_empty(adm4_tokens),
      job_cats = null_if_empty(map(job_cats, \(j) setdiff(j, JOB_IGNORE))),
      phones = null_if_empty(phones)
    )
}

s1 <- export_splink(d1, "d1")
s2 <- export_splink(d2, "d2")

dir.create(dirname(pth$splink_d1), recursive = TRUE, showWarnings = FALSE)
write_parquet(s1, pth$splink_d1)
write_parquet(s2, pth$splink_d2)


## checks: shape and missingness only -----------------------------------------

# rows and columns as read back through arrow
schema_of <- function(path) {
  s <- read_parquet(path, as_data_frame = FALSE)
  tibble(column = names(s), type = map_chr(s$schema$fields, \(f) f$type$ToString()), rows = nrow(s))
}

schema_of(pth$splink_d1)
stopifnot(nrow(read_parquet(pth$splink_d1)) == nrow(d1), nrow(read_parquet(pth$splink_d2)) == nrow(d2))

# tf_tokens and tf_bits line up element for element, with no missing surprisal
stopifnot(
  all(lengths(s1$tf_tokens) == lengths(s1$tf_bits)),
  all(lengths(s2$tf_tokens) == lengths(s2$tf_bits)),
  !anyNA(unlist(s1$tf_bits)),
  !anyNA(unlist(s2$tf_bits))
)

# share of records missing each field (a null list counts as missing)
missing_share <- function(s) {
  s |>
    summarise(across(-c(unique_id, source_dataset), \(x) round(100 * mean(map_lgl(x, is.null) | is.na(x)), 1)))
}

bind_rows(d1 = missing_share(s1), d2 = missing_share(s2), .id = "dataset") |>
  pivot_longer(-dataset, names_to = "column", values_to = "pct_missing") |>
  pivot_wider(names_from = dataset, values_from = pct_missing)
