# 01_ingest.R
# Read the raw datasets and harmonize them to a common schema.
#
# Working files carry only the linkage fields (row key, name, date, age, sex,
# adm1-4) plus the raw phone and occupation fields, which 02_preprocess.R
# cleans. The reference-linkage columns (id_d1, id_d2, order_d1) are split
# off into data-derived/reference.rds, to be touched only by the evaluation
# scripts (06_evaluate.R, 07_project_vaccination.R, 08_plots.R).
#
# Occupation is recorded as one free-text field in D1 (job_raw) and as a set
# of TRUE/FALSE flags with free-text detail columns in D2 (kept under their
# raw names; see R/prep_job.R).
#
# D2 carries two administrative hierarchies: adm[1-3]_d2 from the line list
# itself and adm[1-4]_v_d2 joined from an independent source that also
# supplies the village. The joined hierarchy is used (native values only
# fill its gaps) so that adm1-3 and the village come from one consistent
# source; see scripts/03_audit_fields.R for the aggregate checks behind
# this choice and R/prep_adm.R for the cleaning.

source("R/utils.R")
suppressPackageStartupMessages(library(tidyverse))

d1_raw <- readRDS("data-raw/d1.rds")
d2_raw <- readRDS("data-raw/d2.rds")

# D2 occupation flag / detail columns, carried through under their raw names
D2_JOB_COLS <- c(
  "farmer",
  "butcher",
  "hunter",
  "miner",
  "religiousleader",
  "housewife",
  "student",
  "child",
  "traditional_healer",
  "business",
  "business_type",
  "transporter",
  "transporter_type",
  "hcw",
  "hc_wposition",
  "hcw_facility",
  "other_occup",
  "other_occup_detail"
)

blank_na <- function(x) if_else(is.na(x) | !nzchar(trimws(x)), NA_character_, x)


## harmonize to the common schema ----------------------------------------------
d1 <- d1_raw |>
  transmute(
    row = row_d1,
    name = name_d1,
    date = date_d1,
    age = age_d1,
    sex = sex_d1,
    adm1 = adm1_d1,
    adm2 = adm2_d1,
    adm3 = adm3_d1,
    adm4 = adm4_d1,
    phone_raw = phone_d1,
    job_raw = job_d1
  )

# joined hierarchy first, native line-list values only where it is blank
d2 <- d2_raw |>
  transmute(
    row = row_d2,
    name = name_d2,
    date = date_d2,
    age = age_d2,
    sex = sex_d2,
    adm1 = coalesce(blank_na(adm1_v_d2), adm1_d2),
    adm2 = coalesce(blank_na(adm2_v_d2), adm2_d2),
    adm3 = coalesce(blank_na(adm3_v_d2), adm3_d2),
    adm4 = adm4_v_d2,
    phone_raw = phone_d2,
    across(all_of(D2_JOB_COLS))
  )


## reference linkage (evaluation only) -----------------------------------------
reference <- list(
  d1 = d1_raw |> select(row_d1, id_d1, id_d2, order_d1),
  d2 = d2_raw |> select(row_d2, id_d2)
)


## write -----------------------------------------------------------------------

pth <- paths()
save_derived(d1, pth$d1_harmonized)
save_derived(d2, pth$d2_harmonized)
save_derived(reference, pth$reference)

c(d1 = nrow(d1), d2 = nrow(d2))
