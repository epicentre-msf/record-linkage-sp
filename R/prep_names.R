# Standardization and tokenization of free-text person names.
#
# Designed for ordinary free text names such as "SMITH, John", "Jon R. Smith",
# "Smith, Raymond John": variable numbers of components, variable ordering,
# initials, punctuation, accents. Comparison is token-based and order-free, so
# "SURNAME, First" vs "First Surname" orderings need no special-casing: the
# comma (like all punctuation) becomes a separator and token order is ignored
# downstream.
#

# std_text() from R/utils.R must be sourced first.

# Canonical form of a whole name string.
std_name <- function(x) {
  std_text(x)
}

# List of token vectors, one per input name. Empty tokens dropped; NA input
# yields character(0).
name_tokens <- function(x) {
  x <- std_name(x)
  x[is.na(x)] <- ""
  lapply(strsplit(x, " ", fixed = TRUE), function(t) t[nzchar(t)])
}

# Single-character tokens are treated as initials (e.g. the "R" in
# "Jon R. Smith"); downstream comparison can match them against full tokens
# by first letter.
is_initial <- function(tokens) {
  nchar(tokens) == 1L
}
