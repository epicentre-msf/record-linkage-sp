# Paths of every derived file, in one place, so that the scripts share
# file names and the layout is documented once:
#
#   data-derived/
#     d1_harmonized.rds, d2_harmonized.rds   scripts/01_ingest.R
#     reference.rds                          scripts/01_ingest.R (the reference
#                                            linkage; read by the evaluation only)
#     d1_clean.rds, d2_clean.rds             scripts/02_preprocess.R
#     splink/
#       d1.parquet, d2.parquet               scripts/04_splink_export.R
#       u_cache.json                         splink/train.py
#       predictions.parquet                  splink/predict.py
#       fit.rds, scores.rds, links.rds,      scripts/05_splink_classify.R
#       run.json
#   splink/model.json                        splink/train.py (the fitted model;
#                                            parameters only, committed)
#   output/                                  audit tables (scripts/03_audit_fields.R)
#   output/splink/                           training and prediction charts and
#                                            logs, evaluation tables and figures
#
# Everything under data-derived/ is derived from the raw data and carries
# protected values (names, phone numbers, ids); it is never committed.
#
# Requires: jsonlite (write_run_info).

paths <- function() {
  list(
    d1_harmonized = "data-derived/d1_harmonized.rds",
    d2_harmonized = "data-derived/d2_harmonized.rds",
    d1 = "data-derived/d1_clean.rds",
    d2 = "data-derived/d2_clean.rds",
    reference = "data-derived/reference.rds",
    splink_d1 = "data-derived/splink/d1.parquet",
    splink_d2 = "data-derived/splink/d2.parquet",
    splink_model = "splink/model.json",
    predictions = "data-derived/splink/predictions.parquet",
    fit = "data-derived/splink/fit.rds",
    scores = "data-derived/splink/scores.rds",
    links = "data-derived/splink/links.rds",
    run = "data-derived/splink/run.json",
    out_dir = "output/splink"
  )
}

# saveRDS() that creates the directory on the way.
save_derived <- function(x, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  saveRDS(x, path)
  invisible(path)
}

# Provenance of the classification run (scripts/05_splink_classify.R):
# whatever is passed in `...` plus the time, written as run.json.
write_run_info <- function(...) {
  path <- paths()$run
  info <- c(list(...), list(written = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")))
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(info, path, auto_unbox = TRUE, pretty = TRUE, digits = NA)
  invisible(path)
}

# Named --key=value arguments of an Rscript call (empty in an interactive
# session), e.g. --n1=300000.
cli_args <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  args <- args[grepl("^--[a-z_0-9]+=", args)]
  keys <- sub("^--([a-z_0-9]+)=.*$", "\\1", args)
  vals <- sub("^--[a-z_0-9]+=", "", args)
  stats::setNames(as.list(vals), keys)
}

# One command-line argument, or the default when absent, coerced to the
# type of the default (integer, double, logical, character).
cli_arg <- function(name, default, args = cli_args()) {
  if (is.null(args[[name]])) {
    return(default)
  }
  x <- args[[name]]
  if (is.integer(default)) {
    as.integer(x)
  } else if (is.numeric(default)) {
    as.numeric(x)
  } else if (is.logical(default)) {
    as.logical(x)
  } else {
    x
  }
}
