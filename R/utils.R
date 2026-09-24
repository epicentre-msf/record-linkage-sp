# Shared helpers and privacy guardrails.

# Columns whose values must never be displayed: raw ids, anything
# name-derived (name, name_clean, name_tokens, ...) and anything
# phone-derived (phone_raw, phones, phone_1, ...).
PROTECTED_PATTERN <- "^(id_|name|phone)"

drop_protected <- function(df) {
  df[, !grepl(PROTECTED_PATTERN, names(df)), drop = FALSE]
}

# Safe alternative to head()/glimpse(): displays only non-protected columns.
peek <- function(df, n = 6) {
  print(utils::head(drop_protected(df), n))
  invisible(df)
}

# Repair strings that are not valid UTF-8 (latin1 bytes in a UTF-8 column,
# e.g. a degree sign in "N\xb028"); stri_trans_general() errors on them.
fix_utf8 <- function(x) {
  if (!is.character(x)) {
    x <- as.character(x)
  }
  bad <- !is.na(x) & !validUTF8(x)
  x[bad] <- iconv(x[bad], "latin1", "UTF-8")
  x
}

# Generic free-text standardization: ASCII-fold accents, uppercase,
# non-alphanumeric -> space, collapse whitespace.
std_text <- function(x) {
  x <- fix_utf8(x)
  x <- stringi::stri_trans_general(x, "Latin-ASCII")
  x <- toupper(x)
  x <- gsub("[^A-Z0-9 ]+", " ", x)
  x <- gsub("\\s+", " ", x)
  x <- trimws(x)
  x[!nzchar(x)] <- NA_character_
  x
}

# Aggregate per-column missingness summary (safe to print: counts only).
missingness <- function(df) {
  data.frame(
    col = names(df),
    n_missing = vapply(df, function(x) sum(is.na(x)), integer(1)),
    pct_missing = round(
      100 * vapply(df, function(x) mean(is.na(x)), numeric(1)),
      1
    ),
    row.names = NULL
  )
}

paste_collapse <- function(x, collapse = "; ") {
  if (all(is.na(x))) {
    out <- NA_character_
  } else {
    x_non_missing <- x[!is.na(x)]

    if (length(unique(x_non_missing)) == 1L) {
      out <- unique(x_non_missing)[1L]
    } else {
      out <- paste(x_non_missing, collapse = collapse)
    }
  }

  out
}

source("R/paths.R")
