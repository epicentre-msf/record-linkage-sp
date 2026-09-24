# Classification of scored pairs into links / review / non-links, and
# one-to-one assignment.

# Two-threshold classification on the posterior match probability: >= ACCEPT
# is a link, [REVIEW, ACCEPT) the clerical-review band, below REVIEW a
# non-link (scripts/05_splink_classify.R; the evaluation and plot scripts
# read the same two values).
ACCEPT <- 0.9
REVIEW <- 0.5

# Greedy one-to-one assignment: called with pairs already sorted in priority
# order (descending score), returns TRUE for pairs where neither record has
# been claimed by a higher-priority pair. Assumes each D1 record can link to
# at most one D2 record and vice versa.
greedy_one_to_one <- function(row_1, row_2) {
  stopifnot(length(row_1) == length(row_2))
  f1 <- match(row_1, unique(row_1))
  f2 <- match(row_2, unique(row_2))
  used1 <- logical(max(f1, 0L))
  used2 <- logical(max(f2, 0L))
  sel <- logical(length(f1))
  for (i in seq_along(f1)) {
    if (!used1[f1[i]] && !used2[f2[i]]) {
      sel[i] <- TRUE
      used1[f1[i]] <- TRUE
      used2[f2[i]] <- TRUE
    }
  }
  sel
}

# Greedy one-to-one selection of a scored pair table (data frame with row_1,
# row_2, score): pairs are ranked by descending score, ties broken by the row
# keys, and each record keeps its highest-ranked pair. Returns the table in
# ranked order with a logical `selected` column.
one_to_one <- function(x) {
  x <- x[order(-x$score, x$row_1, x$row_2), , drop = FALSE]
  x$selected <- greedy_one_to_one(x$row_1, x$row_2)
  x
}
