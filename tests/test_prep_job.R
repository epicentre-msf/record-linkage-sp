# Tests for R/prep_job.R using synthetic occupation text only.
# Run: Rscript tests/test_prep_job.R

source("R/utils.R")
source("R/prep_job.R")

cats <- function(x) job_from_text(x)[[1]]
prim <- function(x) job_primary(job_from_text(x))

# --- one category per rule family, tolerant of case / accents / typos ---
stopifnot(identical(cats("Enfant"), "child"))
stopifnot(identical(cats("Enfant non scolarisé"), "child")) # not student
stopifnot(identical(cats("NOURRISSON"), "child"))
stopifnot(identical(cats("Ecolier/ière-Elève"), "student"))
stopifnot(identical(cats("ETUDIANT ISP"), "student"))
stopifnot(identical(cats("Ménagère"), "housewife"))
stopifnot(identical(cats("MENEGERE"), "housewife"))
stopifnot(identical(cats("Sans profession - sans emploi - au chomage"), "none"))
stopifnot(identical(cats("Retraité/e"), "none"))
stopifnot(identical(cats("Cultivateur/trice - Planteur/euse - Agriculteur/trice - Exploitant Forestier"), "farmer"))
stopifnot(identical(cats("Planteur/Eleveur"), "farmer")) # ELEVEUR is not ELEVE
stopifnot(identical(cats("CULTIVIVATEUR"), "farmer"))
stopifnot(identical(cats("Pêcheur"), "farmer"))
stopifnot(identical(cats("Mineur - Orpailleur/euse"), "miner"))
stopifnot(identical(cats("Creuseur d'or"), "miner"))
stopifnot(identical(cats("Commerçant/e-Marchand/e"), "trade"))
stopifnot(identical(cats("VENDEUSE DE TOMATE"), "trade"))
stopifnot(identical(cats("Boucher"), "trade"))
stopifnot(identical(cats("Motard - Taxi moto"), "transport"))
stopifnot(identical(cats("Chaffeur Taxi moto"), "transport"))
stopifnot(identical(cats("Couturier/ière - Tailleur"), "artisan"))
stopifnot(identical(cats("Maçon"), "artisan"))
stopifnot(identical(cats("Mécanicien/ne- Machiniste"), "artisan"))
stopifnot(identical(cats("Personnel de santé: Infirmier/ ière"), "health"))
stopifnot(identical(cats("INFIRMIERE"), "health"))
stopifnot(identical(cats("Agent Riposte: Autre"), "health")) # AUTRE not at start
stopifnot(identical(cats("Relais communautaire (RECO)"), "health"))
stopifnot(identical(cats("Tradipraticien/ne - Médecin traditionnel"), "traditional_healer"))
stopifnot(identical(cats("Médecin traditionnel"), "traditional_healer")) # not health
stopifnot(identical(cats("Personnel de santé: Médecin"), "health"))
stopifnot(identical(cats("Chef religieux"), "religious"))
stopifnot(identical(cats("PASTEUR CEPAC"), "religious"))
stopifnot(identical(cats("Militaire/Policier"), "security"))
stopifnot(identical(cats("Millitaire"), "security"))
stopifnot(identical(cats("Agent de Sécurite - Sentinelle - Gardien"), "security"))
stopifnot(identical(cats("Enseignant/e"), "professional"))
stopifnot(identical(cats("Fonctionnaire de l'état"), "professional"))
stopifnot(identical(cats("Journaliste"), "professional"))

# --- near-miss keywords must not fire ---
stopifnot(identical(cats("Agent de Transport marchandise"), "transport")) # MARCHANDISE
stopifnot(identical(cats("Chef/fe terrien/ne- Chef/fe traditionnel/le"), "professional")) # TRADITIONNEL
stopifnot(identical(cats("DIRECTEUR D'ECOLE PRIMAIRE"), "professional")) # ECOLE
stopifnot(identical(cats("MAITRESSE"), "professional")) # -TRESS-
stopifnot(identical(cats("RENSEIGNEMENT"), "security")) # -ENSEIG-
stopifnot(identical(cats("ETUDIANTE EN MEDECINE"), "student")) # MEDECINE
stopifnot(identical(cats("Laborantin/e - Technicien/ne laboratoire"), "health"))
stopifnot(identical(cats("Chef/fe de Quartier"), "professional"))

# --- other / unknown / empty ---
stopifnot(identical(cats("Autre"), "other"))
stopifnot(identical(cats("Autres occupation - Autre métier"), "other"))
stopifnot(identical(cats("Zork operator"), "other")) # unrecognized text
stopifnot(length(cats("Inconnu")) == 0L)
stopifnot(length(cats("Inc.")) == 0L)
stopifnot(length(cats(NA)) == 0L)
stopifnot(length(cats("")) == 0L)
stopifnot(length(cats(" , ")) == 0L)
# "Autre: X" with a recognizable X gives only X
stopifnot(identical(cats("Autre: Orpailleur"), "miner"))

# --- multi-category text and primary selection ---
stopifnot(identical(cats("Cultivateur / Pasteur"), c("farmer", "religious")))
stopifnot(identical(prim("Cultivateur / Pasteur"), "farmer"))
stopifnot(identical(cats("Chasseur - Vendeur de viande de brousse"), c("farmer", "trade")))
stopifnot(identical(prim("Chasseur - Vendeur de viande de brousse"), "trade"))
stopifnot(identical(prim("MENAGERE / RECO"), "health"))
stopifnot(identical(prim("ELEVE MECANICIEN"), "artisan"))
stopifnot(is.na(prim(NA)))

# Invalid UTF-8 (Latin-1 bytes) does not break matching.
x <- "ELEVE EN 6\xe8me"
Encoding(x) <- "unknown"
stopifnot(identical(cats(x), "student"))

# --- D2: flags plus detail text ---
d2 <- data.frame(
  farmer = c(TRUE, FALSE, FALSE, FALSE, FALSE, TRUE, FALSE, FALSE, FALSE),
  butcher = FALSE,
  hunter = c(FALSE, FALSE, FALSE, FALSE, FALSE, TRUE, FALSE, FALSE, FALSE),
  miner = FALSE,
  religiousleader = FALSE,
  housewife = c(FALSE, TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE),
  student = FALSE,
  child = c(FALSE, FALSE, TRUE, FALSE, FALSE, FALSE, TRUE, FALSE, FALSE),
  traditional_healer = FALSE,
  business = c(FALSE, TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE),
  transporter = FALSE,
  hcw = FALSE,
  other_occup = c(FALSE, FALSE, TRUE, TRUE, FALSE, FALSE, TRUE, TRUE, TRUE),
  other_occup_detail = c(NA, NA, "ELEVE A L'EP KYUHU", "ZORK", NA, "PAYSAN", "AU VILLAGE", "INCONNUE", NA),
  stringsAsFactors = FALSE
)
j <- job_d2(d2)
stopifnot(identical(j[[1]], "farmer"))
stopifnot(identical(j[[2]], c("housewife", "trade"))) # multi-flag
stopifnot(identical(j[[3]], c("child", "student"))) # flag + parsed detail
stopifnot(identical(j[[4]], "other")) # other flag, unrecognized detail
stopifnot(length(j[[5]]) == 0L) # nothing recorded
stopifnot(identical(j[[6]], "farmer")) # farmer + hunter + PAYSAN collapse
stopifnot(identical(j[[7]], "child")) # unrecognized detail adds no "other" to a known flag
stopifnot(length(j[[8]]) == 0L) # other flag with "unknown" detail -> nothing
stopifnot(identical(j[[9]], "other")) # other flag, no detail
stopifnot(identical(job_primary(j)[1:6], c("farmer", "trade", "student", "other", NA, "farmer")))
stopifnot(identical(job_string(j)[c(2, 5)], c("housewife|trade", NA)))

# Every category is reachable and every priority entry is a category.
stopifnot(setequal(JOB_PRIORITY, JOB_CATEGORIES))

cat("All prep_job tests passed.\n")
