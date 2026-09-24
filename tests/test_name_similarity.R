# Tests for R/name_similarity.R using synthetic names only.
# Run: Rscript tests/test_name_similarity.R

suppressPackageStartupMessages(library(data.table))
source("R/utils.R")
source("R/prep_names.R")
source("R/name_similarity.R")

sim1 <- function(a, b) name_similarity(name_tokens(a), name_tokens(b))

# Identical names, different component order and formatting -> exact agreement.
stopifnot(sim1("SMITH, John", "John Smith") == 1)
stopifnot(sim1("Smith, Raymond John", "Raymond John SMITH") == 1)

# Initials match their full token ("R" ~ "Raymond"); small spelling variation
# ("Jon" ~ "John") stays a strong match.
stopifnot(sim1("Jon R. Smith", "SMITH, John Raymond") > 0.9)

# Typos remain in partial-agreement territory.
stopifnot(sim1("Jhon Smiht", "John Smith") > 0.75)

# A namesake sharing one token lands in the weak band (0.75-0.85).
s_namesake <- sim1("John Smith", "John Martin")
stopifnot(s_namesake >= 0.75, s_namesake < 0.85)

# Unrelated names disagree.
stopifnot(sim1("John Smith", "Pauline Mukwege") < 0.75)

# Missing / empty names -> NA.
stopifnot(is.na(sim1(NA, "John Smith")))
stopifnot(is.na(sim1("", "")))

# Vectorized over aligned lists.
s <- name_similarity(name_tokens(c("A B", NA)), name_tokens(c("B A", "X Y")))
stopifnot(length(s) == 2L, s[1] == 1, is.na(s[2]))

# The README table, to three decimals.
readme <- tibble::tribble(
  ~a                    , ~b                    , ~score ,
  "MUKENDI Jean"        , "Jean Mukendi"        , 1.000  ,
  "SMITH, John"         , "Jon Smith"           , 0.967  ,
  "Jon R. Smith"        , "Smith, Raymond John" , 0.961  ,
  "Smith, Raymond John" , "John Smith"          , 0.911  ,
  "John Smith"          , "John Martin"         , 0.794  ,
  "John Smith"          , "Paul Jones"          , 0.413
)
stopifnot(all(round(name_similarity(name_tokens(readme$a), name_tokens(readme$b)), 3) == readme$score))

cat("All name similarity tests passed.\n")
