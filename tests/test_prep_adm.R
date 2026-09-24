# Tests for R/prep_adm.R using synthetic place names only.
# Run: Rscript tests/test_prep_adm.R

source("R/utils.R")
source("R/prep_adm.R")

one <- function(x) adm4_tokens(x)[[1]]
same_set <- function(a, b) setequal(a, b) && length(a) == length(b)

# --- plain names: folded, upper-cased, single token ---
stopifnot(identical(one("Mambango"), "MAMBANGO"))
stopifnot(identical(one("  mambango "), "MAMBANGO"))
stopifnot(identical(one("Bwana-Sura"), c("BWANA", "SURA")))
stopifnot(identical(one("Cité Belge"), c("CITE", "BELGE"))) # accent folded, CITE kept

# --- type prefixes dropped ---
stopifnot(identical(one("Q. Madidi"), "MADIDI"))
stopifnot(identical(one("Q/MADIDI"), "MADIDI"))
stopifnot(identical(one("CELLULE VUVISWA"), "VUVISWA"))
stopifnot(identical(one("Cel Ngwati"), "NGWATI"))
stopifnot(identical(one("Av Bamate"), "BAMATE"))
stopifnot(identical(one("Cartier Vatican"), "VATICAN"))
stopifnot(identical(one("VIL BUTAMA"), "BUTAMA"))
stopifnot(identical(one("Q. de l'Hopital"), "HOPITAL")) # function words and single chars

# --- house numbers dropped, with and without the degree sign ---
stopifnot(identical(one("RUGHENDA N°258"), "RUGHENDA"))
stopifnot(identical(one("MAKASI N53"), "MAKASI"))
stopifnot(identical(one("KALUVO NO34"), "KALUVO"))
stopifnot(identical(one("Q 9 AV NK NUM 107"), "NK"))
stopifnot(identical(one("Vuliki N225"), "VULIKI"))
# latin1-encoded degree sign (invalid UTF-8) is repaired, not fatal
x <- "OFFICE N\xb012"
Encoding(x) <- "unknown"
stopifnot(identical(one(x), "OFFICE"))

# --- kilometre posts become one token ---
stopifnot(identical(one("PK 14"), "PK14"))
stopifnot(identical(one("SOME PK26"), c("SOME", "PK26")))
stopifnot(identical(one("SOME 26KM"), c("SOME", "PK26")))
stopifnot(identical(one("PK 26 KM"), "PK26"))
stopifnot(identical(one("20 KM KAMANGO"), c("PK20", "KAMANGO")))

# --- subdivision numbers: multi-character kept, single characters dropped ---
stopifnot(identical(one("OICHA 1"), "OICHA"))
stopifnot(identical(one("BUTIABA I"), "BUTIABA"))
stopifnot(identical(one("MASANGE II"), c("MASANGE", "II")))
stopifnot(identical(one("300 MAISONS"), c("300", "MAISONS")))

# --- nested places in one cell: all tokens kept, order-free set ---
stopifnot(same_set(one("CELL. IVATAMA / Q. KIMBULU"), c("IVATAMA", "KIMBULU")))
stopifnot(same_set(one("KAMUSONGE/ Q.WAYENE, C BULENGERA"), c("KAMUSONGE", "WAYENE", "BULENGERA")))
stopifnot(same_set(one("Mabanga Sud/ Katoyi"), c("MABANGA", "SUD", "KATOYI")))
stopifnot(same_set(one("BUHUMBANI (QUARTIER NOGERA)"), c("BUHUMBANI", "NOGERA")))
# the shared-token property the comparison relies on
stopifnot(length(intersect(one("Q. Kimbulu N°45"), one("CELL. IVATAMA / Q. KIMBULU"))) == 1L)
# duplicates within a cell collapse
stopifnot(identical(one("Madidi / Q. Madidi"), "MADIDI"))

# --- nothing usable -> empty ---
stopifnot(length(one(NA)) == 0L)
stopifnot(length(one("")) == 0L)
stopifnot(length(one("Q.")) == 0L)
stopifnot(length(one("N°12")) == 0L)
stopifnot(identical(adm4_std(c("Q. Madidi", NA, "Q.", "PK 14")), c("MADIDI", NA, NA, "PK14")))

# --- vectorised shape ---
out <- adm4_tokens(c("Q. Madidi", NA, "CELL. IVATAMA / Q. KIMBULU"))
stopifnot(is.list(out), length(out) == 3L, lengths(out) == c(1L, 0L, 2L))

# --- snap_rare_levels: rare near-duplicates of a frequent value ---
x <- c(rep("NORD KIVU", 200), rep("ITURI", 50), "NORD KIV", "NORS KIVU", "NORD VKIVU", "MABALAKO", NA)
y <- snap_rare_levels(x)
stopifnot(identical(y[251:253], rep("NORD KIVU", 3)))
stopifnot(identical(y[254], "MABALAKO")) # dissimilar rare value untouched
stopifnot(is.na(y[255]))
stopifnot(identical(y[1:250], x[1:250]))
# a rare value that is a distinct place (low similarity) is kept
stopifnot(identical(snap_rare_levels(c(rep("BENI", 100), "KATWA"))[101], "KATWA"))
# all-frequent or all-rare inputs are returned unchanged
stopifnot(identical(snap_rare_levels(c("A", "B")), c("A", "B")))
stopifnot(identical(snap_rare_levels(c(NA_character_, NA_character_)), c(NA_character_, NA_character_)))

# --- cross-dataset vocabulary alignment ---
# a value absent from the reference vocabulary is snapped to its nearest
# reference value at JW >= theta; values present in both are never touched,
# and neither are values too far from anything
al <- align_vocab(
  c("BIAKATO MINES", "BIAKATO MINES", "BINGO", "IDHOU", "FARAWAY", NA),
  c("BIAKATO MINE", "BIAKATO MAYI", "BINGO", "BIGO", "IDOU")
)
stopifnot(identical(al$x, c("BIAKATO MINE", "BIAKATO MINE", "BINGO", "IDOU", "FARAWAY", NA)))
stopifnot(identical(al$map$from, c("BIAKATO MINES", "IDHOU")), identical(al$map$n, c(2L, 1L)))
# max_n: only values carried by fewer than max_n records are eligible
al2 <- align_vocab(c("IDHOU", "IDHOU", "MAKOKO2"), c("IDOU", "MAKOKO"), max_n = 2)
stopifnot(identical(al2$x, c("IDHOU", "IDHOU", "MAKOKO")))
# empty reference or nothing to align
stopifnot(identical(align_vocab(c("A", "B"), character(0))$x, c("A", "B")))
stopifnot(nrow(align_vocab(c("A", "B"), c("A", "B"))$map) == 0L)
# token sets: every token is mapped, sets de-duplicated
at <- align_tokens(
  list(c("IVATAMA", "KIMBULU"), "MUTHONE", c("MUTONE", "MUTHONE"), character(0)),
  list("KIMBULU", "MUTONE", "IVATAMA")
)
stopifnot(identical(at$tokens, list(c("IVATAMA", "KIMBULU"), "MUTONE", "MUTONE", character(0))))
stopifnot(identical(at$map$from, "MUTHONE"), identical(at$map$n, 2L))

cat("test_prep_adm: all passed\n")
