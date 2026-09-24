# Token-based name similarity: the R reference implementation of the
# similarity that the Splink name comparison computes in DuckDB SQL
# (NAME_SIM in splink/comparisons.py). The pipeline itself scores pairs in
# Splink; this function documents the measure in plain R, is validated on
# synthetic names in tests/test_name_similarity.R, and is what
# tests/test_splink_name_sql.py checks the SQL against.
#
# Names are free text ("SMITH, John", "Jon R. Smith", "Smith, Raymond
# John") with a variable number of components in a variable order, so the
# comparison is token-based and order-insensitive: a symmetric Monge-Elkan
# average over Jaro-Winkler token similarities.
#
# Requires: data.table, stringdist; name_tokens() from R/prep_names.R
# produces the token sets.

# Symmetric Monge-Elkan name similarity between two aligned lists of token
# vectors: for each token in A the best Jaro-Winkler match in B, averaged, and
# vice versa, then averaged. Order-free by construction. A single-letter token
# (an initial) matching the other token's first letter counts as strong
# agreement (0.95). Returns NA where either token set is empty.
#
# Worked example: "Jon R. Smith" vs "SMITH, John Raymond" arrive here (after
# name_tokens() in R/prep_names.R) as c("JON", "R", "SMITH") and c("SMITH",
# "JOHN", "RAYMOND"). Every A token is compared with every B token by
# Jaro-Winkler: "JON" finds "JOHN" (0.93), "R" finds "RAYMOND" (0.74 by JW,
# lifted to 0.95 by the initial rule), "SMITH" finds "SMITH" (1). The mean
# of those bests is the A -> B score; the B -> A score is built the same
# way from B's viewpoint ("RAYMOND" finds "R", ...), and the two are
# averaged, here to 0.96. Neither the order nor the number of name
# components has to agree, which is what free-text names in this setting
# require.
name_similarity <- function(tokens_1, tokens_2) {
  # tokens_1[[i]] and tokens_2[[i]] are the two token sets of pair i, so the
  # lists must have the same length. p and q are the number of tokens on
  # each side of every pair. A pair with no tokens on either side (an empty
  # name after cleaning) cannot be scored and keeps the NA that `out` is
  # pre-filled with. `ok` holds the positions of the scorable pairs;
  # everything below works only on those, and the early return covers the
  # all-empty case, which the data.table code below could not handle.
  stopifnot(length(tokens_1) == length(tokens_2))
  p <- lengths(tokens_1)
  q <- lengths(tokens_2)
  out <- rep(NA_real_, length(tokens_1))
  ok <- which(p > 0L & q > 0L)
  if (length(ok) == 0L) {
    return(out)
  }

  # Unnest the token sets into two long tables, one row per (pair, token).
  # Looping over pairs and calling stringdist on each would be far too slow
  # for many pairs; instead the whole input is scored with a handful of
  # vectorized operations. pid is the pair's position in the input lists
  # (and so in `out`), ia/ib the token's position within its own name,
  # ta/tb the token text. rep(ok, p[ok]) repeats each pair index once per
  # token that pair has, sequence(p[ok]) generates 1..p for each pair, and
  # unlist() flattens the tokens in the same order, so the three columns
  # line up element-for-element.
  la <- data.table::data.table(
    pid = rep(ok, p[ok]),
    ia = sequence(p[ok]),
    ta = unlist(tokens_1[ok])
  )
  lb <- data.table::data.table(
    pid = rep(ok, q[ok]),
    ib = sequence(q[ok]),
    tb = unlist(tokens_2[ok])
  )

  # Token cross-product within each pair. X[Y, on = "pid"] is data.table's
  # join syntax: for each row of Y, the rows of X with the same pid. A pair
  # with 3 tokens on each side yields 3 x 3 = 9 rows. allow.cartesian = TRUE
  # opts into that many-to-many blow-up, which data.table otherwise refuses
  # as a likely mistake.
  tp <- la[lb, on = "pid", allow.cartesian = TRUE]

  # Jaro-Winkler similarity for every token pair (stringdist returns a
  # distance in [0, 1], so 1 - distance is the similarity). JW is designed
  # for short strings such as names: it rewards matching characters and
  # transpositions rather than counting edits, and p = 0.1 adds a bonus for
  # a shared prefix (up to four characters), so "JON"/"JOHN" score higher
  # than an edit distance would suggest. := adds the column in place.
  tp[, sim := 1 - stringdist::stringdist(ta, tb, method = "jw", p = 0.1)]

  # Initial rule: a single-character token equal to the first letter of the
  # other token counts as strong agreement. JW alone scores "R" vs "RAYMOND"
  # poorly (few matching characters), yet an initial is a legitimate way to
  # record a name component. The dt[i, j] form filters rows with i and then
  # assigns with j, so only the rows meeting the condition are touched;
  # pmax() keeps the JW value where it happens to be higher.
  tp[nchar(ta) == 1L & ta == substr(tb, 1L, 1L), sim := pmax(sim, 0.95)]
  tp[nchar(tb) == 1L & tb == substr(ta, 1L, 1L), sim := pmax(sim, 0.95)]

  # Monge-Elkan in each direction. For side A: group by (pair, A token) and
  # take the best similarity over the B tokens, then group by pair and
  # average those bests. `.()` is data.table shorthand for list() and names
  # the summary columns; `by` groups. me_a is one row per pair: how well
  # each A token is explained by some B token. me_b is the same from B's
  # point of view. Doing both directions makes the measure symmetric;
  # otherwise a short name would score very differently against a long one
  # depending on which side it appeared on.
  me_a <- tp[, .(best = max(sim)), by = .(pid, ia)][, .(me = mean(best)), by = pid]
  me_b <- tp[, .(best = max(sim)), by = .(pid, ib)][, .(me = mean(best)), by = pid]

  # Average the two directions and write the result back at the positions
  # of the scorable pairs (s$pid indexes into `out`). merge() lines the two
  # tables up by pair; .x/.y are the suffixes merge() gives two columns of
  # the same name.
  s <- merge(me_a, me_b, by = "pid")
  out[s$pid] <- (s$me.x + s$me.y) / 2

  out
}
