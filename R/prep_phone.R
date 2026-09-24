# Cleaning of free-text phone-number fields.
#
# Raw entries are mostly plain digit strings, but also include:
#   * multiple numbers in one cell, separated by "," "/" ";" or whitespace;
#   * whitespace or dashes inside a single number ("081 234 5678");
#   * Excel-mangled values in scientific notation ("8.1234567891234567E+18"),
#     which arise when two numbers were typed into one numeric cell: the
#     leading zero of the first number is dropped and the concatenated
#     19-digit integer exceeds double precision, so only the first number
#     can be recovered reliably;
#   * stray letters, punctuation, or mojibake attached to a number;
#   * entries with no digits at all (e.g. a name typed in the phone field).
#
# clean_phone() splits each entry into its component numbers, reduces each to
# a canonical digit string, and returns one column per number (phone_1,
# phone_2, ...). Anything that does not yield a plausible number becomes NA.
#
# Canonical form (DRC numbering): a 9-digit national number. International
# prefixes ("+243", "243", "00243", "0243") and a leading trunk "0" are
# removed. Digit strings of other lengths (typos, missing digits) are kept
# as-is when within `min_digits`..`max_digits` so that downstream comparison
# can still use them; outside that range they become NA.
#
# Two output shapes: clean_phone() returns a wide tibble (phone_1, phone_2,
# ...); phone_set() returns a list-column of canonical numbers per record,
# the shape used by the pipeline (like name_tokens), so that a record with
# several numbers compares as a set. Canonical numbers are as protected as
# the raw field: never display them (see PROTECTED_PATTERN in R/utils.R).

suppressPackageStartupMessages(library(tibble))

# Excel-style scientific notation, e.g. "8.12345678912E+18". Returns the
# integer digit string, or NA if not scientific notation.
phone_sci_to_digits <- function(x) {
  is_sci <- grepl("^\\s*[0-9]+(\\.[0-9]+)?[Ee][+-]?[0-9]+\\s*$", x)
  out <- rep(NA_character_, length(x))
  out[is_sci] <- sprintf("%.0f", as.numeric(x[is_sci]))
  out
}

# Split one raw entry into pieces, each intended to be a single number.
# Explicit separators are "," "/" ";" and "+". Dashes and other punctuation
# are treated as formatting inside a number and removed later. Whitespace separates numbers only when every whitespace-
# delimited chunk is itself a long digit run (>= `split_min`); otherwise
# whitespace is treated as formatting inside a single number and removed.
phone_split_one <- function(x, split_min) {
  if (is.na(x)) {
    return(character(0))
  }
  sci <- phone_sci_to_digits(x)
  if (!is.na(sci)) {
    # A double holds ~15 significant digits. A longer integer is two numbers
    # concatenated: the first 9 digits (leading 0 lost) are exact; the rest
    # has lost its trailing digits and is unrecoverable.
    if (nchar(sci) > 15) {
      return(c(substr(sci, 1, 9), NA_character_))
    }
    return(sci)
  }
  pieces <- strsplit(x, "[,/;+]", perl = TRUE)[[1]]
  pieces <- trimws(pieces)
  pieces <- pieces[nzchar(pieces)]
  unlist(
    lapply(pieces, function(p) {
      chunks <- strsplit(p, "\\s+", perl = TRUE)[[1]]
      chunks <- chunks[nzchar(chunks)]
      chunk_digits <- nchar(gsub("[^0-9]", "", chunks))
      if (length(chunks) > 1 && all(chunk_digits >= split_min)) chunks else p
    })
  )
}

# Reduce a piece to canonical digits (or NA).
phone_canonical <- function(p, min_digits, max_digits) {
  # letter O typed between digits is a zero
  d <- gsub("(?<=[0-9])\\s*[Oo](?=\\s*[0-9])", "0", p, perl = TRUE)
  d <- gsub("[^0-9]", "", d)
  d[is.na(d)] <- ""
  # strip international prefix (243 / 0243 / 00243), then trunk prefix 0,
  # each only when what remains is a full 9-digit national number
  d <- sub("^0{0,2}243(?=[0-9]{9}$)", "", d, perl = TRUE)
  d <- sub("^0(?=[0-9]{9}$)", "", d, perl = TRUE)
  n <- nchar(d)
  bad <- n < min_digits | n > max_digits | grepl("^([0-9])\\1*$", d, perl = TRUE) # repeated single digit, e.g. 000000000
  d[bad] <- NA_character_
  d
}

# Main entry point.
#
# x          character vector of raw phone entries
# max_n      number of phone_k columns to return (default: the maximum number
#            of pieces found in any entry)
# min_digits / max_digits   plausible length range for a canonical number
# split_min  minimum digits per chunk for whitespace to count as a separator
#
# Returns a tibble with columns phone_1 .. phone_{max_n}, one row per input.
clean_phone <- function(x, max_n = NULL, min_digits = 7L, max_digits = 12L, split_min = 7L) {
  pieces <- phone_set(x, min_digits = min_digits, max_digits = max_digits, split_min = split_min)
  n_found <- lengths(pieces)
  if (is.null(max_n)) {
    max_n <- max(1L, n_found)
  }
  mat <- t(
    vapply(
      pieces,
      function(p) {
        p <- p[seq_len(min(length(p), max_n))]
        c(p, rep(NA_character_, max_n - length(p)))
      },
      character(max_n)
    )
  )
  colnames(mat) <- paste0("phone_", seq_len(max_n))
  as_tibble(mat)
}

# Set form: a list with one character vector of distinct canonical numbers
# per input (character(0) when none). Identical entries are cleaned once.
phone_set <- function(x, min_digits = 7L, max_digits = 12L, split_min = 7L) {
  x <- as.character(x)
  u <- unique(x)
  sets <- lapply(u, function(v) {
    p <- phone_split_one(v, split_min = split_min)
    p <- phone_canonical(p, min_digits, max_digits)
    unique(p[!is.na(p)])
  })
  sets[match(x, u)]
}

# Drop numbers carried by many records. A personal number appears on one
# record per dataset, a few for a household or for repeat visits; a number
# on more than `max_records` records across both datasets is a facility or
# community line and identifies nobody. Such numbers are removed from both
# list-columns (a record left without a number is missing on phone).
# Returns list(sets_1, sets_2, n_dropped = number of distinct numbers
# removed, n_records = records that lost a number).
phone_drop_shared <- function(sets_1, sets_2, max_records = 10L) {
  count_records <- function(sets) {
    t <- unique(
      data.frame(
        row = rep(seq_along(sets), lengths(sets)),
        ph = unlist(sets),
        stringsAsFactors = FALSE
      )
    )
    table(t$ph)
  }
  k1 <- count_records(sets_1)
  k2 <- count_records(sets_2)
  nums <- union(names(k1), names(k2))
  k <- as.integer(k1[nums])
  k[is.na(k)] <- 0L
  k2v <- as.integer(k2[nums])
  k2v[is.na(k2v)] <- 0L
  common <- nums[k + k2v > max_records]
  strip <- function(sets) {
    hit <- vapply(sets, function(p) any(p %in% common), logical(1))
    sets[hit] <- lapply(sets[hit], setdiff, common)
    list(sets = sets, n = sum(hit))
  }
  s1 <- strip(sets_1)
  s2 <- strip(sets_2)
  list(
    sets_1 = s1$sets,
    sets_2 = s2$sets,
    n_dropped = length(common),
    n_records = s1$n + s2$n
  )
}
