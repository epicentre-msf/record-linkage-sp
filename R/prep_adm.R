# Cleaning of the administrative-area fields.
#
# adm1-3 are the health-pyramid levels (province / health zone / health
# area) recorded as free text; std_text() (R/utils.R) is enough for them,
# plus snap_rare_levels() for the handful of typos at the province level.
#
# adm4 is the village / quartier field and needs more: the two datasets
# record it at different granularities and with different conventions.
# Observed forms (both datasets, aggregate inspection only):
#
#   * place-type prefixes: "Q. MADIDI", "Q/MADIDI", "CELLULE VUVISWA",
#     "CELL. IVATAMA", "AV BAMATE", "Cartier Vatican", "VIL BUTAMA";
#   * house numbers: "RUGHENDA N°258", "MAKASI N53", "KALUVO NO34",
#     "AV FATUMA 105" (the degree sign is often latin1-encoded);
#   * kilometre posts on a road: "PK 14", "SOME PK26", "SOME 26KM",
#     "PK 26 KM";
#   * numbered subdivisions: "OICHA 1", "BANGOLE 2", "BUTIABA I",
#     "MASANGE II", "300 MAISONS";
#   * several nested places in one cell, separated by "/" or ",":
#     "CELL. IVATAMA / Q. KIMBULU", "KAMUSONGE/ Q.WAYENE, C BULENGERA",
#     "Mabanga Sud/ Katoyi";
#   * the health area or zone name repeated as the village ("Butembo").
#
# std_adm4() reduces a value to an order-free set of place-name tokens:
# ASCII-folded upper-case words with the type words, French function
# words, house numbers and single characters removed, kilometre posts
# joined into one token ("PK14"). adm4_tokens() returns that set as a
# list-column (like name_tokens), adm4_std() as one space-joined string for
# exact use (blocking keys). A record whose D1 value is "Q. Kimbulu N°45"
# and whose D2 value is "CELL. IVATAMA / Q. KIMBULU" then share the token
# KIMBULU, which is the intended unit of comparison: nested places in one
# cell are all legitimate, so a village comparison should reward the best
# shared token rather than average over all of them.
#
# Multi-character subdivision numbers ("II", "300") are kept as tokens; the
# single-character ones ("OICHA 1", "BUTIABA I") go with the other single
# characters, so numbered parts of one place share the place token. Bare
# house numbers without a marker ("FATUMA 105") survive as digit tokens,
# which is harmless under a best-token comparison.

# Requires: stringdist (snap_rare_levels)

# Place-type words and French function words that carry no place identity.
# Descriptive words that are part of proper names (CITE, CAMP, CENTRE,
# BASE, SITE, HOME, MAISONS, MILITAIRE) are deliberately kept.
ADM4_TYPE_WORDS <- c(
  "Q",
  "QUARTIER",
  "CARTIER",
  "QTIER",
  "CEL",
  "CELL",
  "CELLULE",
  "AV",
  "AVENUE",
  "RUE",
  "BLOC",
  "VIL",
  "VILLAGE",
  "LOC",
  "LOCALITE",
  "COMMUNE",
  "COM",
  "GROUPEMENT",
  "GRPT",
  "DE",
  "DU",
  "DES",
  "LA",
  "LE",
  "ET",
  "AU",
  "PRES",
  "VERS"
)

# Token sets: list of character vectors, one per input; NA or a value with
# no usable token yields character(0).
adm4_tokens <- function(x) {
  x <- std_text(x)
  # house numbers: "N 28" (from "N°28"), "N243", "NO 34", "NUM 107"
  x <- gsub("\\b(N|NO|NR|NUM|NUMERO) ?[0-9]+\\b", " ", x, perl = TRUE)
  # kilometre posts -> one token: "PK 14", "PK 26 KM", "26 KM", "26KM"
  x <- gsub("\\bPK ?([0-9]+)( ?KM)?\\b", "PK\\1", x, perl = TRUE)
  x <- gsub("\\b([0-9]+) ?KM\\b", "PK\\1", x, perl = TRUE)
  x[is.na(x)] <- ""
  lapply(
    strsplit(x, " ", fixed = TRUE),
    function(t) {
      t <- t[nchar(t) >= 2L & !t %in% ADM4_TYPE_WORDS]
      unique(t)
    }
  )
}

# Space-joined token string (tokens in original order), NA when empty.
adm4_std <- function(x) {
  s <- vapply(adm4_tokens(x), paste, character(1), collapse = " ")
  s[!nzchar(s)] <- NA_character_
  s
}

# Replace rare spelling variants of a categorical field by the frequent
# value they resemble: a value carried by fewer than `min_share` of the
# non-missing records is snapped to the most similar value carried by at
# least `min_share`, if that Jaro-Winkler similarity is >= `theta`. Meant for
# small vocabularies where near-identical strings cannot be distinct
# places (provinces: "NORD KIV", "NORS KIVU" -> "NORD KIVU"); at finer
# levels neighbouring places can have near-identical names, so there the
# variants are better left to a fuzzy pairwise comparison.
snap_rare_levels <- function(x, min_share = 0.01, theta = 0.9) {
  tab <- table(x)
  freq <- names(tab)[tab >= min_share * sum(tab)]
  rare <- setdiff(names(tab), freq)
  if (length(rare) == 0L || length(freq) == 0L) {
    return(x)
  }
  sim <- 1 - stringdist::stringdistmatrix(rare, freq, method = "jw", p = 0.1)
  best <- apply(sim, 1, which.max)
  best_sim <- apply(sim, 1, max)
  to <- ifelse(best_sim >= theta, freq[best], rare)
  is_rare <- !is.na(x) & x %in% rare
  x[is_rare] <- to[match(x[is_rare], rare)]
  x
}

# Align a categorical vocabulary across the two datasets. A value of `x`
# that does not occur in `ref` (the other dataset's values) is replaced by
# its most similar value of `ref` when that Jaro-Winkler similarity is at
# least `theta`; values that occur in both vocabularies are never touched,
# so two frequent near-identical names that both datasets use (BINGO /
# BIGO, MANGINA / MANGIVA -- distinct health areas) stay distinct, while a
# spelling that only one dataset uses (BIAKATO MINES vs BIAKATO MINE,
# IDHOU vs IDOU) is harmonized. With `max_n`, only values carried by fewer
# than `max_n` records of `x` are eligible: used for the direction from the
# large dataset (D1) to the small one (D2), where a frequent D1 value absent
# from D2 is far more likely a place D2 simply has no cases from than a
# misspelling. Returns list(x = aligned values, map = data.frame of the
# replacements with record counts and similarities).
align_vocab <- function(x, ref, theta = 0.94, max_n = Inf) {
  ref <- unique(ref[!is.na(ref)])
  tab <- table(x)
  cand <- names(tab)[!names(tab) %in% ref & tab < max_n]
  map <- data.frame(from = character(0), to = character(0), n = integer(0), jw = numeric(0))
  if (length(cand) == 0L || length(ref) == 0L) {
    return(list(x = x, map = map))
  }
  sim <- 1 - stringdist::stringdistmatrix(cand, ref, method = "jw", p = 0.1)
  sim <- matrix(sim, nrow = length(cand))
  best <- apply(sim, 1, which.max)
  best_sim <- apply(sim, 1, max)
  keep <- best_sim >= theta
  map <- data.frame(
    from = cand[keep],
    to = ref[best[keep]],
    n = as.integer(tab[cand[keep]]),
    jw = round(best_sim[keep], 3),
    stringsAsFactors = FALSE
  )
  hit <- !is.na(x) & x %in% map$from
  x[hit] <- map$to[match(x[hit], map$from)]
  list(x = x, map = map)
}

# The same for token-set list-columns (adm4_tokens): the vocabulary is the
# set of tokens, counted once per record, and every token of every record
# is mapped (sets de-duplicated afterwards).
align_tokens <- function(tokens, ref_tokens, theta = 0.94, max_n = Inf) {
  rec_tok <- unique(
    data.frame(
      row = rep(seq_along(tokens), lengths(tokens)),
      tok = unlist(tokens),
      stringsAsFactors = FALSE
    )
  )
  al <- align_vocab(
    rec_tok$tok,
    unique(unlist(ref_tokens)),
    theta = theta,
    max_n = max_n
  )
  map <- al$map
  if (nrow(map) == 0L) {
    return(list(tokens = tokens, map = map))
  }
  hit <- vapply(tokens, function(t) any(t %in% map$from), logical(1))
  tokens[hit] <- lapply(
    tokens[hit],
    function(t) {
      m <- match(t, map$from)
      unique(ifelse(is.na(m), t, map$to[m]))
    }
  )
  list(tokens = tokens, map = map)
}
