# Tests for R/token_surprisal.R on synthetic data only.
# Run: Rscript tests/test_token_surprisal.R

suppressPackageStartupMessages(library(data.table))
source("R/token_surprisal.R")

# --- token_long: full tokens only, unique per row ---
d <- data.table(
  row = 1:3,
  name_tokens = list(
    c("smith", "j", "smith"),
    c("smith", "john", "raymond"),
    character(0)
  )
)
tl <- token_long(d)
stopifnot(nrow(tl) == 4L, all(nchar(tl$token) >= 2L), !anyDuplicated(tl))

# --- token_surprisal on synthetic names ---
# d1: 4 records, d2: 2 records. Token record counts (pooled, N = 6):
#   smith 6, john 3, rare 2  ->  s = -log2((n + 2) / 6)
d1 <- data.table(
  row = 1:4,
  name_tokens = list(
    c("smith", "john"),
    c("smith", "rare"),
    c("smith", "john"),
    "smith"
  )
)
d2 <- data.table(
  row = 1:2,
  name_tokens = list(
    c("smith", "john", "rare"),
    "smith"
  )
)
tf <- token_surprisal(token_long(d1), token_long(d2), nrow(d1) + nrow(d2))
s <- function(n) -log2((n + TF_SMOOTH_ADD) / 6)
setkey(tf, token)
stopifnot(nrow(tf) == 3L)
stopifnot(identical(tf[c("smith", "john", "rare"), n], c(6L, 3L, 2L)))
stopifnot(all(abs(tf[c("smith", "john", "rare"), s] - s(c(6, 3, 2))) < 1e-12))

# a token on every record has almost no surprisal; the rarer the token,
# the more bits
stopifnot(tf["smith", s] < tf["john", s], tf["john", s] < tf["rare", s])

cat("test_token_surprisal.R: all tests passed\n")
