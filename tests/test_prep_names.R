# Tests for R/prep_names.R using synthetic names only.
# Run: Rscript tests/test_prep_names.R

source("R/utils.R")
source("R/prep_names.R")

tokset <- function(x) sort(name_tokens(x)[[1]])

# --- std_name: case, punctuation, accents, whitespace ---
stopifnot(std_name("SMITH, John") == "SMITH JOHN")
stopifnot(std_name("  jon  r.  smith ") == "JON R SMITH")
stopifnot(std_name("Jean-Pierre N'Golo") == "JEAN PIERRE N GOLO")
stopifnot(std_name("Müller, François") == "MULLER FRANCOIS")
stopifnot(is.na(std_name(NA)))
stopifnot(is.na(std_name("  ,. ")))

# --- name_tokens: order-free token sets ---
# "SURNAME, First" and "First Surname" yield the same token set.
stopifnot(identical(tokset("SMITH, John"), tokset("John Smith")))
stopifnot(identical(tokset("Smith, Raymond John"), c("JOHN", "RAYMOND", "SMITH")))
# Variable component counts are preserved as-is.
stopifnot(length(name_tokens("Jon R. Smith")[[1]]) == 3L)
stopifnot(length(name_tokens("Smith")[[1]]) == 1L)
# NA / empty input -> empty token vector.
stopifnot(length(name_tokens(NA)[[1]]) == 0L)
stopifnot(length(name_tokens("")[[1]]) == 0L)
# Vectorized: one element per input.
stopifnot(length(name_tokens(c("A B", "C", NA))) == 3L)

# --- is_initial ---
toks <- name_tokens("Jon R. Smith")[[1]]
stopifnot(identical(is_initial(toks), c(FALSE, TRUE, FALSE)))

cat("All prep_names tests passed.\n")
