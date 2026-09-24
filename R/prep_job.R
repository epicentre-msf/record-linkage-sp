# Standardization of occupation ("job") into a small set of broad categories.
#
# The two sources record occupation differently:
#   * D1: one free-text field, mixing coded dropdown values ("Cultivateur/trice
#     - Planteur/euse - Agriculteur/trice - Exploitant Forestier",
#     "Personnel de santé: Infirmier/ ière") with typed text ("Millitaire",
#     "VENDEUSE DE TOMATE", "ELEVE A L'EP KITULU").
#   * D2: one TRUE/FALSE flag per category (farmer, butcher, hunter, miner,
#     religiousleader, housewife, student, child, traditional_healer,
#     business, transporter, hcw, other_occup), each of the last four with a
#     free-text detail column (business_type, transporter_type, hc_wposition,
#     other_occup_detail). Several flags can be TRUE for one record.
#
# Both are mapped to the same categories (JOB_CATEGORIES) with the same
# keyword rules (JOB_RULES), applied to ASCII-folded upper-case text, so that
# a person recorded as "Enseignante" in D1 and as other_occup = TRUE /
# other_occup_detail = "ENSEIGNANT A L'EP TAHA" in D2 lands in the same
# category. A record may carry several categories (D2 multi-flags; D1 text
# such as "Cultivateur / Pasteur"), so the primary representation is a SET
# (list-column `job_cats`); `job_primary()` reduces a set to one category by
# a fixed priority order for use as a single categorical field.
#
# Design choices:
#   * Categories describe the person's occupation, not their workplace: a
#     guard or accountant at a hospital is security / professional, not
#     health. The one exception is the outbreak response itself (riposte,
#     EDS, CTE, RECO, PCI, ...): working for the response is treated as a
#     health occupation, matching how D2 uses its hcw flag (its hc_wposition
#     values include "AGENT DE LA RIPOSTE" and "RELAIS COMMUNAUTAIRE").
#   * "Mineur" in D1 is taken as miner, not minor (the coded option is
#     "Mineur - Orpailleur/euse"; children are coded "Enfant").
#   * Hunters are folded into farmer (primary-sector subsistence); butchers
#     into trade; teachers into professional. These keep the number of
#     categories near a dozen; nothing prevents finer splits later, but the
#     rule sets below would need to be split accordingly.
#   * Explicit "unknown" answers (Inconnu, Inc, "son père", ...) and empty
#     text become NA. Explicit "Autre"/"Divers", and any non-empty text that
#     no rule recognizes, become "other": the person has a stated occupation
#     that the scheme does not cover, which is itself comparable across
#     datasets (D2's other_occup flag means the same thing).
#
# Requires: std_text() from R/utils.R.

JOB_CATEGORIES <- c(
  "child", # infant / child not (yet) at school
  "student", # pupil or student at any level
  "housewife", # ménagère / homemaker
  "none", # no occupation: unemployed, retired, elderly
  "farmer", # agriculture, livestock, fishing, hunting, forestry
  "miner", # mining, gold digging, stone breaking
  "trade", # commerce: vendors, shopkeepers, traders, butchers
  "transport", # drivers, motorcycle taxis, transporters
  "artisan", # manual trades, labourers, personal services, arts, sport
  "health", # health workers and outbreak-response workers
  "traditional_healer", # tradipraticien / médecin traditionnel
  "religious", # pastors, priests, other religious leaders
  "security", # military, police, guards
  "professional", # teachers, civil servants, office, NGO, professions
  "other" # stated occupation not covered above
)

# Priority for reducing a set of categories to one (first present wins):
# specific occupations before generic statuses.
JOB_PRIORITY <- c(
  "traditional_healer",
  "health",
  "miner",
  "security",
  "transport",
  "trade",
  "farmer",
  "artisan",
  "professional",
  "religious",
  "student",
  "housewife",
  "child",
  "none",
  "other"
)
stopifnot(setequal(JOB_PRIORITY, JOB_CATEGORIES))

# Categories the job comparison ignores (scripts/04_splink_export.R drops
# them from the exported sets): "child" is nearly determined by age, which
# the model already compares, so it would be counted twice; "other" means
# only "not in the list". A record left with no category is missing on job.
JOB_IGNORE <- c("child", "other")

# Text that means "unknown": mapped to NA rather than a category.
JOB_UNKNOWN_PATTERN <- paste(
  c(
    "^INC$",
    "^INCONNU",
    "^NSP$",
    "^INDETERMIN",
    "^NON (RENSEIGNE|PRECISE|SPECIFIE)",
    "^SON (PERE|FRERE|MARI|ONCLE)",
    "^SA (MERE|SOEUR|FEMME|TANTE)",
    "^\\?+$"
  ),
  collapse = "|"
)

# Explicit "other": only used when no specific rule matches (see
# job_from_text). Unrecognized text is treated the same way.
JOB_OTHER_PATTERN <- "^AUTRES?\\b|^DIVERS$|^AUTRES? (OCCUPATION|METIER)"

# Keyword rules, applied with perl regexes to std_text()-normalized strings
# (upper-case ASCII, punctuation replaced by single spaces). Patterns are
# deliberately tolerant of the misspellings seen in typed entries. A string
# may match several rules.
JOB_RULES <- list(
  child = paste(
    c(
      "\\bENFANTS?\\b",
      "\\bEMFANT",
      "NOURRIS",
      "NOURIS",
      "\\bBEBE\\b",
      "NOUVEAU NE",
      "NE PAR CESAR"
    ),
    collapse = "|"
  ),
  student = paste(
    c(
      "\\bELEVES?\\b",
      "\\bELENE\\b",
      "\\bENEVE\\b",
      "\\bECOLIER",
      "\\bECILOI",
      "ETUDIANT",
      "EDUDIANT",
      "APPRENTI",
      "FINALISTE"
    ),
    collapse = "|"
  ),
  housewife = "MENAG|MENEG",
  none = paste(
    c(
      "SANS (PROFESSION|EMPLOI|METIER|OCCUPATION|TRAVAIL|ACTIVITE)",
      "^SANS$",
      "CHOMAGE",
      "CHOMEUR",
      "RETRAIT",
      "VIEUIL",
      "VIEILL",
      "3EME AGE",
      "^AUCUNE?$",
      "^NEANT$",
      "^RAS\\b",
      "DEBROUILL",
      "^PATIENT$"
    ),
    collapse = "|"
  ),
  farmer = paste(
    c(
      "CULTIV",
      "CULTUV",
      "COULTUV",
      "CLTIV",
      "CUTIV",
      "AGRICULT",
      "PLANTEUR",
      "PANTEUR",
      "ELEVEUR",
      "ELEVAGE",
      "PAYSAN",
      "PECHEUR",
      "\\bPECHE\\b",
      "FORESTIER",
      "BERGER",
      "JARDI",
      "\\bFERME\\b",
      "EXPLOITANT",
      "CHASSEUR",
      "\\bCHASSE\\b",
      "VIANDE DE BROUSSE",
      "CONVOYEUR DE BOEUFS"
    ),
    collapse = "|"
  ),
  miner = paste(
    c(
      "MINEUR",
      "MINIER",
      "\\bMINES?\\b",
      "ORPAIL",
      "OR PAIL",
      "ORPALL",
      "CREUSEUR",
      "CRESEUR",
      "CASSEUR DE PIERRE",
      "CANCEUR DES PIERRES",
      "CONCASSEUR",
      "COCASS",
      "CARRIER"
    ),
    collapse = "|"
  ),
  trade = paste(
    c(
      "COMMER",
      "COMER",
      "COMMEC",
      "VENDEU",
      "VENSEU",
      "VANDEU",
      "MARCHAND(?!ISE)",
      "MARCHANT",
      "FOURNISSEUR",
      "BOUTIQU",
      "REVENDEU",
      "AMBULANT",
      "NEGOCIANT",
      "BOUCHER",
      "DETAILLANT",
      "\\bVENTE\\b",
      "ACHETEUR",
      "ACHETREUR",
      "BRAISEUR",
      "FRIPERIE"
    ),
    collapse = "|"
  ),
  transport = paste(
    c(
      "CHAUFFEUR",
      "CHAFFEUR",
      "MOTARD",
      "\\bMOTAR\\b",
      "TAXI",
      "TRANSPORT",
      "CONVOYEUR VEHICULE",
      "TSHUKUD",
      "CHUKUD",
      "AMBULANCI",
      "CHARETIER",
      "CHARRETIER",
      "POIDS? LOUR",
      "CAMION",
      "AVIATEUR"
    ),
    collapse = "|"
  ),
  artisan = paste(
    c(
      "COUTUR",
      "COUTIR",
      "CUTURI",
      "TAILLE+U",
      "CHARPENT",
      "CHARPANT",
      "MACON",
      "MANCON",
      "MENUIS",
      "MENUSI",
      "MENOU",
      "PEINTR",
      "PINTRE",
      "MECANIC",
      "MACHINIST",
      "COIFF",
      "CLOIFF",
      "\\bTRESS",
      "TRAISS",
      "DRESSEUSE",
      "ELECTRIC",
      "ELECTRONIC",
      "ELECTROMEC",
      "MANUTENT",
      "MANUTATION",
      "MANITATION",
      "MANUNTENT",
      "BOMBEU",
      "FORGERON",
      "CORDONN",
      "CORDONI",
      "COORDONN",
      "COORDONI",
      "COODONN",
      "PLOMBI",
      "SOUDEU",
      "LAVEUR",
      "LAVADEUR",
      "LAVADIER",
      "JOURNALIER",
      "OUVRIER",
      "MANOEUVRE",
      "BOULANG",
      "PATISS",
      "CUISINI",
      "SERVEU",
      "SERVENTE",
      "RESTAURANT",
      "HOTELI",
      "DOMESTIQUE",
      "REPARAT",
      "TOU[ST] TRAV",
      "PETITS? TRAVAUX",
      "SCIEUR",
      "PRESSEUR",
      "BRIQUE",
      "FERRAIL",
      "FERAILL",
      "FERRAY",
      "POMPISTE",
      "VITRIER",
      "VERNISS",
      "ARTISAN",
      "ARTISTE",
      "MUSICIEN",
      "SCULPT",
      "DECORAT",
      "PHOTOGRAPH",
      "IMPRIMEUR",
      "CONSTRUCT",
      "CARREL",
      "CANTONI",
      "CANTONN",
      "BOULONN",
      "TECHNICIEN(?![A-Z ]*LABO)",
      "MAINTENANC",
      "MEUNIER",
      "MENIER",
      "MOULIN",
      "USINE",
      "TRIEUSE",
      "TRILLEUSE",
      "CHIMISTE",
      "SALONNEUR",
      "SPORTIF",
      "FOOTBALL",
      "BOXEUR",
      "BASKET",
      "KARAT",
      "DANSEUSE",
      "CLEANER",
      "ENTRETIEN",
      "FABRICANT"
    ),
    collapse = "|"
  ),
  health = paste(
    c(
      "SANTE",
      "SANITAIRE",
      "INVESTIGAT",
      "INFIRM",
      "INFIEM",
      "INFIRL",
      "\\bMEDECINS?\\b(?! TRADI)",
      "MEDCIN",
      "PHARMAC",
      "DOCTEUR",
      "HYGIEN",
      "HIGIEN",
      "LABO",
      "PHARMACIEN",
      "SOIGNANT",
      "SAGE FEMME",
      "ACCOUCHEU",
      "RIPOSTE",
      "\\bEDS\\b",
      "\\bCTE?\\b",
      "\\bRECO\\b",
      "RELAIS COMM",
      "\\bPCI\\b",
      "\\bPCT\\b",
      "\\bHP\\b",
      "\\bAPS\\b",
      "\\bPEC\\b",
      "\\bPOE\\b",
      "\\bIDR\\b",
      "PSYCHO",
      "PSYCOLOG",
      "NUTRITIONN?IST",
      "AMBULANC",
      "SECOURISTE",
      "CROIX ROUGE",
      "TRIAGE",
      "SURVEILLANCE",
      "RECHERCHE ACTIVE",
      "VACCINAT",
      "PRELEVEMENT",
      "OPHTA",
      "ANESTH",
      "ANSTHE",
      "DENTISTE",
      "\\bP E C\\b",
      "KINESI",
      "PROMOTION DE LA SANTE",
      "POINT D ENTREE",
      "BERCEUSE",
      "GARDE MALADE",
      "ACCOMPAGNANT",
      "FILLE DE SALLE"
    ),
    collapse = "|"
  ),
  traditional_healer = paste(
    c(
      "TRADI ?PRA",
      "\\bTRADI\\b",
      "MEDECIN TRADI",
      "COUTUMI",
      "GUERISSEUR",
      "FETICHEUR",
      "HERBORIST"
    ),
    collapse = "|"
  ),
  religious = paste(
    c(
      "PASTEUR",
      "PRETRE",
      "RELIGI",
      "EVANG",
      "CHANTRE",
      "DIACRE",
      "EGLIS",
      "PAROISSE",
      "PASTORAL",
      "CATECH",
      "\\bIMAM\\b",
      "MOSQUEE",
      "\\bFIDELE\\b",
      "REVERE"
    ),
    collapse = "|"
  ),
  security = paste(
    c(
      "MILIT",
      "MILLIT",
      "POLIC",
      "FORCES? DE SECU",
      "FORCES? DE L ORDRE",
      "SECURIT",
      "SECUTIT",
      "SECURIS",
      "GARDIEN",
      "GARDIENT",
      "GARDIENAGE",
      "GARDIENNAGE",
      "SENTIN",
      "SANTIN",
      "DENTINELLE",
      "\\bANR\\b",
      "FARDC",
      "COMBATTANT",
      "MAIMAI",
      "MAI MAI",
      "SOLDAT",
      "ARMEE",
      "POMPIER",
      "RENSEIGNEMENT",
      "PORTIER"
    ),
    collapse = "|"
  ),
  professional = paste(
    c(
      "\\bENSEIG",
      "\\bESEIGN",
      "PROF+ESSEUR",
      "INSTITUTEUR",
      "MAITRESSE",
      "DIRECTEUR",
      "PREFET",
      "INSPECTEUR",
      "FONCTION",
      "AGENT DE L ?ETAT",
      "EGENT DE L ETAT",
      "ADMINISTRAT",
      "SECRETAIRE",
      "SECRETAIRE",
      "COMPTABLE",
      "RECEPTION",
      "INFORMATICI",
      "JOURNALIST",
      "AVOCAT",
      "\\bJUGE\\b",
      "JURISTE",
      "HUISSIER",
      "INGENIEUR",
      "INGENIERE",
      "ARCHITECTE",
      "ARCHIVISTE",
      "AGRONOME",
      "LOGISTICIEN",
      "DATA MANAGER",
      "\\bONG\\b",
      "HUMANITAI",
      "OXFAM",
      "MONUSCO",
      "CHEF( FE)?( DE| DU)? (QUARTIER|VILLAGE|CELLULE|GROUPEMENT|NOTAB|TERRIEN|TRADITION|COUTUM|D ENTENE)",
      "NOTABLE",
      "NOTABILITE",
      "DOUANE",
      "DOUANNE",
      "\\bDGDA\\b",
      "\\bDGI\\b",
      "REGIE",
      "\\bRVA\\b",
      "\\bSNEL\\b",
      "SODEICO",
      "OFFICE DE ROUTE",
      "TRANSCOM",
      "\\bEPSP\\b",
      "DIVISION",
      "MAIRIE",
      "TAXATEUR",
      "PERCEPTEUR",
      "CONTROLEUR",
      "COMMISSAIRE",
      "DECLARANT",
      "VERIFICATEUR",
      "ETAT CIVIL",
      "ENVIRON",
      "TOURISME",
      "CONSULTANT",
      "ENTREPREN",
      "LIBERALE",
      "ACTIVISTE",
      "ANIMATEUR",
      "SUPERVISEUR",
      "TEAM LEADER",
      "COORDINAT",
      "COMMUNICATION",
      "COMMUNICOLOGUE",
      "POINT FOCAL",
      "SOUS DIVISION",
      "EXPATRI",
      "VETERINAIRE",
      "GERANT"
    ),
    collapse = "|"
  )
)
stopifnot(setequal(names(JOB_RULES), setdiff(JOB_CATEGORIES, "other")))

# Normalize free text for rule matching. Some typed entries carry Latin-1
# bytes that are not valid UTF-8; they are re-encoded before std_text() so
# that accent folding does not fail on them.
std_job_text <- function(x) {
  x <- as.character(x)
  bad <- !is.na(x) & !validUTF8(x)
  x[bad] <- iconv(x[bad], from = "latin1", to = "UTF-8", sub = "")
  std_text(x)
}

# Map free text to category sets. Returns a list (one character vector per
# input, sorted; character(0) for NA / empty / unknown text).
job_from_text <- function(x) {
  s <- std_job_text(x)
  n <- length(s)
  hit <- matrix(FALSE, nrow = n, ncol = length(JOB_RULES), dimnames = list(NULL, names(JOB_RULES)))
  ok <- !is.na(s) & !grepl(JOB_UNKNOWN_PATTERN, s, perl = TRUE)
  for (cat in names(JOB_RULES)) {
    hit[ok, cat] <- grepl(JOB_RULES[[cat]], s[ok], perl = TRUE)
  }
  none_matched <- ok & rowSums(hit) == 0L
  out <- lapply(seq_len(n), function(i) sort(names(JOB_RULES)[hit[i, ]]))
  out[none_matched] <- list("other")
  out
}

# D1: a single free-text field.
job_d1 <- function(job_text) {
  job_from_text(job_text)
}

# D2: category flags plus free-text detail. `d` must contain the logical
# columns farmer, butcher, hunter, miner, religiousleader, housewife,
# student, child, traditional_healer, business, transporter, hcw,
# other_occup and the character column other_occup_detail. The typed detail
# columns for business / transporter / hcw are not parsed: the flag already
# fixes the category. other_occup_detail is parsed with the same rules as
# D1 text (regardless of the other_occup flag). "other" is assigned only
# when nothing more specific is known: from unrecognized detail text, or
# from other_occup = TRUE without usable detail, and only if no flag gave a
# category. Detail text meaning "unknown" gives nothing.
JOB_D2_FLAGS <- c(
  farmer = "farmer",
  hunter = "farmer",
  butcher = "trade",
  business = "trade",
  miner = "miner",
  religiousleader = "religious",
  housewife = "housewife",
  student = "student",
  child = "child",
  traditional_healer = "traditional_healer",
  transporter = "transport",
  hcw = "health"
)

job_d2 <- function(d) {
  stopifnot(all(c(names(JOB_D2_FLAGS), "other_occup", "other_occup_detail") %in% names(d)))
  n <- nrow(d)
  from_flags <- lapply(
    seq_len(n),
    function(i) {
      on <- vapply(names(JOB_D2_FLAGS), function(f) isTRUE(d[[f]][i]), logical(1))
      unname(JOB_D2_FLAGS[on])
    }
  )
  from_text <- job_from_text(d$other_occup_detail)
  detail_std <- std_job_text(d$other_occup_detail)
  unknown_text <- !is.na(detail_std) & grepl(JOB_UNKNOWN_PATTERN, detail_std, perl = TRUE)
  other_flag <- !is.na(d$other_occup) & d$other_occup & !unknown_text
  out <- lapply(
    seq_len(n),
    function(i) {
      cats <- union(from_flags[[i]], from_text[[i]])
      if (length(cats) == 0L && other_flag[i]) {
        cats <- "other"
      }
      if (length(cats) > 1L) {
        cats <- setdiff(cats, "other")
      }
      sort(cats)
    }
  )
  out
}

# Reduce category sets to one category by JOB_PRIORITY (NA for empty sets).
job_primary <- function(cats) {
  vapply(
    cats,
    function(x) {
      if (length(x) == 0L) {
        return(NA_character_)
      }
      JOB_PRIORITY[match(TRUE, JOB_PRIORITY %in% x)]
    },
    character(1)
  )
}

# Category sets as a single "|"-separated string (NA for empty), e.g. for
# aggregate tabulation.
job_string <- function(cats) {
  out <- vapply(cats, paste, character(1), collapse = "|")
  out[!nzchar(out)] <- NA_character_
  out
}
