# Tests for R/prep_phone.R using synthetic phone entries only.
# Run: Rscript tests/test_prep_phone.R

source("R/prep_phone.R")

one <- function(x) phone_set(x)[[1]]

# --- canonical form: 9-digit national number ---
stopifnot(identical(one("812345678"), "812345678"))
stopifnot(identical(one("0812345678"), "812345678")) # trunk 0
stopifnot(identical(one("243812345678"), "812345678")) # country code
stopifnot(identical(one("+243 812 345 678"), "812345678")) # +, spaces
stopifnot(identical(one("00243812345678"), "812345678")) # 00 prefix
stopifnot(identical(one("0243812345678"), "812345678")) # 0 + country code
stopifnot(identical(one("081-234-5678"), "812345678")) # dashes
stopifnot(identical(one("(+243)812345678"), "812345678"))

# Letter O between digits is a zero.
stopifnot(identical(one("8123O5678"), "812305678"))

# --- multiple numbers in one entry ---
stopifnot(identical(one("0812345678, 0991234567"), c("812345678", "991234567")))
stopifnot(identical(one("0812345678/0991234567"), c("812345678", "991234567")))
stopifnot(identical(one("0812345678; 0991234567"), c("812345678", "991234567")))
# whitespace separates numbers only when every chunk is a long digit run
stopifnot(identical(one("0812345678 0991234567"), c("812345678", "991234567")))
stopifnot(identical(one("0812 345 678"), "812345678"))
# duplicates within an entry collapse
stopifnot(identical(one("0812345678 / 812345678"), "812345678"))

# --- Excel scientific notation ---
# single number typed into a numeric cell (leading 0 lost)
stopifnot(identical(one("812345678"), one("8.12345678E8")))
# two numbers concatenated in one numeric cell: only the first 9 digits are
# recoverable
stopifnot(identical(one("8.1234567809912345E+18"), "812345678"))

# --- implausible entries -> none ---
stopifnot(length(one(NA)) == 0L)
stopifnot(length(one("")) == 0L)
stopifnot(length(one("INCONNU")) == 0L)
stopifnot(length(one("12345")) == 0L) # too short
stopifnot(length(one("000000000")) == 0L) # repeated digit
stopifnot(length(one("12345678901234")) == 0L) # too long

# Out-of-range-but-plausible lengths are kept for downstream fuzzy use.
stopifnot(identical(one("81234567"), "81234567")) # 8 digits (missing one)
stopifnot(identical(one("8123456789"), "8123456789")) # 10 digits (extra one)

# --- phone_set is vectorized and preserves alignment ---
s <- phone_set(c("0812345678", NA, "0812345678, 0991234567", "abc"))
stopifnot(length(s) == 4L)
stopifnot(identical(lengths(s), c(1L, 0L, 2L, 0L)))
stopifnot(identical(s[[1]], "812345678"))

# --- clean_phone: wide form ---
w <- clean_phone(c("0812345678", "0812345678, 0991234567", NA))
stopifnot(identical(names(w), c("phone_1", "phone_2")))
stopifnot(nrow(w) == 3L)
stopifnot(identical(w$phone_1, c("812345678", "812345678", NA)))
stopifnot(identical(w$phone_2, c(NA, "991234567", NA)))
w3 <- clean_phone(c("0812345678", NA), max_n = 3)
stopifnot(identical(names(w3), c("phone_1", "phone_2", "phone_3")))

# --- numbers on many records are dropped from both datasets ---
s1 <- list(c("111111112", "222222223"), "111111112", "111111112", "333333334", character(0))
s2 <- list("111111112", c("222222223", "333333334"))
ds <- phone_drop_shared(s1, s2, max_records = 3)
stopifnot(identical(ds$sets_1, list("222222223", character(0), character(0), "333333334", character(0))))
stopifnot(identical(ds$sets_2, list(character(0), c("222222223", "333333334"))))
stopifnot(ds$n_dropped == 1L, ds$n_records == 4L)
ds0 <- phone_drop_shared(s1, s2, max_records = 10)
stopifnot(identical(ds0$sets_1, s1), ds0$n_dropped == 0L)

cat("All prep_phone tests passed.\n")
