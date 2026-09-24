# Surprisal of a name token: how much evidence agreement on that token is.
#
# The fitted u for a name-agreement level is one global coincidence rate,
# but coincidence probability is value-specific: for a random D1 x D2 pair,
# sharing token t has probability about f_t^2, so agreement on a rare
# token is far stronger evidence than on the most common surname in the
# dataset. Each full token is therefore priced by its surprisal
#
#   s_t = -log2 f_t,   f_t = (n_t + TF_SMOOTH_ADD) / N_records
#
# with n_t the number of records (over D1 and D2 pooled) containing the
# token. The Splink name comparison (splink/comparisons.py) sums the
# surprisals of the tokens the two names hold exactly in common (the
# pair's shared surprisal) and splits each similarity level by it, so
# that the value of a rare shared token is estimated from the data like
# any other level. scripts/04_splink_export.R computes the table below
# once and writes each record's full tokens and their surprisals side by
# side for the SQL to sum.
#
# Policy choices, fixed from aggregate token statistics (not tuned against
# the reference):
#  - frequencies are pooled record shares over D1 u D2, smoothed by adding
#    TF_SMOOTH_ADD to each record count: most tokens are singletons, and a
#    singleton may be a data-entry artifact, so +2 caps a singleton's
#    surprisal at about 14.4 bits (with 63,600 records) instead of 16;
#  - only full tokens (length >= 2) are priced; an initial is shared with
#    every name starting with that letter, so its frequency says nothing
#    useful about how surprising an agreement is.
#
# Requires: data.table.

TF_SMOOTH_ADD <- 2

# Long unique (row, token) table of full (length >= 2) tokens for one dataset.
# d$name_tokens is a list-column (one character vector per record); rep()
# repeats each record's row key once per token it holds, so `row` and
# `token` line up element-for-element. unique() collapses a token repeated
# within one name, so that a record counts at most once towards a token's
# frequency.
token_long <- function(d) {
  t <- data.table::data.table(
    row = rep(d$row, lengths(d$name_tokens)),
    token = unlist(d$name_tokens)
  )
  unique(t[nchar(token) >= 2L])
}

# Per-token surprisal table (token, n, s) from the long token tables of the
# two datasets. Pooled frequency: stack both datasets' token tables and
# count the records containing each token (.N is data.table's row count
# within a `by` group). The share of records containing token t,
# f_t = n / n_rec, becomes a surprisal s = -log2 f_t in bits: a token in
# half the records has 1 bit of surprisal, one in a thousandth about 10
# bits. The smoothing constant is added to the count before the log, so a
# token seen once is priced as if seen three times (see the header).
token_surprisal <- function(t1, t2, n_rec) {
  tf <- data.table::rbindlist(list(t1, t2))[, .(n = .N), by = token]
  tf[, s := -log2((n + TF_SMOOTH_ADD) / n_rec)]
  tf[]
}
