# Tests for R/classify.R.
# Run: Rscript tests/test_classify.R

source("R/classify.R")

# Pairs pre-sorted by descending score. Greedy: a-x taken; a-y blocked (a
# used); b-y taken; b-x blocked (both used); c-z taken.
row_1 <- c("a", "a", "b", "b", "c")
row_2 <- c("x", "y", "y", "x", "z")
stopifnot(identical(greedy_one_to_one(row_1, row_2), c(TRUE, FALSE, TRUE, FALSE, TRUE)))

# A pair is blocked when either side is already claimed: (1,5) takes both
# 1 and 5, so (1,6) and (2,5) are both blocked.
stopifnot(identical(greedy_one_to_one(c(1, 1, 2), c(5, 6, 5)), c(TRUE, FALSE, FALSE)))

# Works with integer keys and empty input.
stopifnot(identical(greedy_one_to_one(integer(0), integer(0)), logical(0)))

cat("All classify tests passed.\n")
