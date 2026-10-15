#!/bin/bash
# =============================================================================
# Sauvegarde quotidienne du VPS Portfolio (backup-portfolio.timer, 03:00)
#
#   sql/  bases MariaDB (portfolio_wp, dc_database)
#   www/  /var/www de chaque site (portfolio, dotclear, brasserie)
#   cfg/  configuration : hôte (iptables, ipset, fail2ban, sudoers, Cockpit, config LXC)
#         + /etc de chaque container en marche (nginx, certificats Let's Encrypt, ...)
#
# - Chaque archive est écrite en .part, VÉRIFIÉE (gzip/tar/fin de dump SQL), puis renommée
#   et accompagnée d'un .sha256. Une archive vide ou corrompue n'est jamais conservée.
# - Le script sort en code 1 si une sauvegarde a échoué (visible dans `systemctl --failed`).
# - Les containers sont trouvés sous leur ancien OU nouveau nom (avant/après renommage).
# - Copie distante optionnelle et CHIFFRÉE : voir /etc/backup_portfolio.conf (exemple en bas).
#
# Variables d'environnement utiles pour tester sans toucher à la prod :
#   BACKUP_ROOT=/chemin  LOG=/chemin/log  CONF=/chemin/conf  SKIP_OFFSITE=1
# =============================================================================
set -uo pipefail
umask 077

BACKUP_ROOT="${BACKUP_ROOT:-/root/backups}"
LOG="${LOG:-/var/log/backup_portfolio.log}"
CONF="${CONF:-/etc/backup_portfolio.conf}"

# Valeurs par défaut (surchargeables dans $CONF)
KEEP_SQL=14          # nombre de sauvegardes conservées par série
KEEP_WWW=7
KEEP_CFG=14
MAX_AGE_DAYS=30      # plafond d'âge, appliqué seulement si la nuit s'est bien passée
MIN_FREE_GB=3
OFFSITE_URL=""       # ex. ftp://ftp.example.org/backups_vps/  (vide = pas de copie distante)
OFFSITE_NETRC=/root/.netrc.backup
OFFSITE_PASSFILE=/root/.backup_passphrase
OFFSITE_KEEP=7
OFFSITE_WWW_WEEKDAY=7   # les archives www (lourdes) ne partent que ce jour-là (1=lun..7=dim, 0=tous les jours)

if [ -f "$CONF" ]; then
    if [ "$(stat -c %u "$CONF")" != 0 ] || [ -n "$(find "$CONF" -perm /022)" ]; then
        echo "$CONF doit appartenir à root et ne pas être modifiable par d'autres" >&2
        exit 2
    fi
    # shellcheck disable=SC1090
    . "$CONF"
fi

STAMP="$(date +%Y-%m-%d_%H-%M)"
SQL_DIR="$BACKUP_ROOT/sql"
WWW_DIR="$BACKUP_ROOT/www"
CFG_DIR="$BACKUP_ROOT/cfg"
TMP="$BACKUP_ROOT/.tmp"
FAILS=0
NEWFILES=()

mkdir -p "$SQL_DIR" "$WWW_DIR" "$CFG_DIR" "$TMP" || exit 2
chmod 700 "$BACKUP_ROOT"
exec > >(tee -a "$LOG") 2>&1

exec 9>"$BACKUP_ROOT/.lock"
# Verrou pris = sauvegarde manquée : code 1 pour déclencher l'alerte OnFailure (le 07/10/2026 un verrou
# resté tenu par des services relancés a bloqué les sauvegardes 2 jours sans aucune alerte).
flock -n 9 || { echo "$(date '+%F %T') ÉCHEC : verrou $BACKUP_ROOT/.lock déjà tenu ($(fuser "$BACKUP_ROOT/.lock" 2>/dev/null)), sauvegarde non faite"; exit 1; }
trap 'rm -rf "$TMP"/*' EXIT

log()  { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
fail() { FAILS=$((FAILS + 1)); log "FAIL $*"; }

is_running() { [ "$(lxc-info -n "$1" -sH 2>/dev/null)" = RUNNING ]; }
pick_ct() { local n; for n in "$@"; do is_running "$n" && { echo "$n"; return 0; }; done; return 1; }

# --- vérifications d'intégrité ------------------------------------------------
check_gz()  { gzip -t < "$1"; }
check_sql() { gzip -t < "$1" && zcat < "$1" | tail -n 1 | grep -q 'Dump completed'; }
check_tar() { tar -tzf "$1" > /dev/null; }

# commit <fichier.part> <fichier final> <libellé> <fonction de contrôle>
commit() {
    local part=$1 out=$2 label=$3 check=$4
    if [ -s "$part" ] && "$check" "$part"; then
        mv -f -- "$part" "$out"
        ( cd "$(dirname "$out")" && sha256sum -- "$(basename "$out")" > "$(basename "$out").sha256" )
        NEWFILES+=("$out")
        log "OK   $label -> $out ($(du -h "$out" | cut -f1))"
    else
        rm -f -- "$part"
        fail "$label (archive vide ou corrompue)"
    fi
}

# --- bases de données -----------------------------------------------------------
backup_db() { # backup_db <base> <container> [<autre nom possible>...]
    local db=$1 ct out; shift
    ct=$(pick_ct "$@") || { fail "sql $db : container ($*) arrêté ou introuvable"; return; }
    out="$SQL_DIR/${db}_${STAMP}.sql.gz"
    # --lock-all-tables et non --single-transaction : portfolio_wp contient surtout des tables MyISAM,
    # que --single-transaction ne fige pas (dump incohérent si une écriture survient pendant la copie).
    if lxc-attach -n "$ct" -- mysqldump -u root --lock-all-tables --routines --triggers --events "$db" | gzip > "$out.part"; then
        commit "$out.part" "$out" "sql  $ct/$db" check_sql
    else
        rm -f -- "$out.part"; fail "sql  $ct/$db (mysqldump)"
    fi
}

# --- applis Alpine (PocketBase & co : SQLite dans /var/lib/<service>) ---------------
# Service arrêté ~1 s pendant le tar : copie cohérente des bases SQLite (WAL vidé).
backup_app() { # backup_app <container=service>
    local ct=$1 out="$SQL_DIR/app_${1}_${STAMP}.tar.gz" rc
    is_running "$ct" || { log "SKIP app  $ct (container arrêté)"; return; }
    lxc-attach -n "$ct" -- rc-service "$ct" stop > /dev/null 2>&1
    lxc-attach -n "$ct" -- tar -C / -czf - "var/lib/$ct" > "$out.part"; rc=$?
    # 9>&- : le service relancé ne doit PAS hériter du descripteur du verrou (sinon il le garde à vie)
    lxc-attach -n "$ct" -- rc-service "$ct" start > /dev/null 2>&1 9>&- || fail "app  $ct : redémarrage du service"
    if [ "$rc" -eq 0 ]; then
        commit "$out.part" "$out" "app  $ct" check_tar
    else
        rm -f -- "$out.part"; fail "app  $ct (tar code $rc)"
    fi
}

# --- sites ---------------------------------------------------------------------
backup_www() { # backup_www <libellé> <container> [<autre nom possible>...]
    local label=$1 ct out rc; shift
    ct=$(pick_ct "$@") || { fail "www  $label : container ($*) arrêté ou introuvable"; return; }
    out="$WWW_DIR/www_${label}_${STAMP}.tar.gz"
    lxc-attach -n "$ct" -- tar -C / -czf - var/www > "$out.part"; rc=$?
    # tar sort 1 quand un fichier change pendant la lecture (ex. cache) : non bloquant
    if [ "$rc" -le 1 ]; then
        commit "$out.part" "$out" "www  $ct" check_tar
    else
        rm -f -- "$out.part"; fail "www  $ct (tar code $rc)"
    fi
}

# --- configuration ---------------------------------------------------------------
backup_cfg_host() {
    local out="$CFG_DIR/cfg_host_${STAMP}.tar.gz" paths=() p rc
    for p in /etc/iptables /etc/ipset /etc/fail2ban /etc/ssh/sshd_config.d /etc/cloud/cloud.cfg.d \
             /etc/sudoers.d /etc/systemd/system /etc/cockpit /etc/lxc /etc/logrotate.d \
             /etc/backup_portfolio.conf /usr/local/sbin /usr/local/libexec /usr/share/cockpit/lxc /etc/logs-central /var/lib/lxc/logs/rootfs/usr/local/bin \
             /var/lib/lxc/*/config; do
        [ -e "$p" ] && paths+=("${p#/}")
    done
    tar -C / -czf "$out.part" "${paths[@]}"; rc=$?
    if [ "$rc" -le 1 ]; then
        commit "$out.part" "$out" "cfg  hôte" check_tar
    else
        rm -f -- "$out.part"; fail "cfg  hôte (tar code $rc)"
    fi
}

backup_cfg_ct() { # /etc complet du container (nginx, certificats, php, fail2ban, mysql...)
    local ct=$1 out rc
    out="$CFG_DIR/cfg_${ct}_${STAMP}.tar.gz"
    local opt=--ignore-failed-read
    # Alpine : tar de BusyBox, qui ne connaît pas --ignore-failed-read
    lxc-attach -n "$ct" -- tar --version 2> /dev/null | grep -q 'GNU tar' || opt=
    lxc-attach -n "$ct" -- tar -C / -czf - $opt etc > "$out.part"; rc=$?
    if [ "$rc" -le 1 ]; then
        commit "$out.part" "$out" "cfg  $ct" check_tar
    else
        rm -f -- "$out.part"; fail "cfg  $ct (tar code $rc)"
    fi
}

# --- rétention -----------------------------------------------------------------
# Garde les N plus récentes de CHAQUE série (préfixe avant la date), donc une série
# qui cesse d'être produite n'est jamais effacée par la rétention des autres.
prune_dir() { # prune_dir <dossier> <N>
    local dir=$1 keep=$2 series f
    while read -r series; do
        ls -1t "$dir/${series}"_[0-9][0-9][0-9][0-9]-* 2> /dev/null | grep -v '\.sha256$' \
            | tail -n +$((keep + 1)) | while read -r f; do rm -f -- "$f" "$f.sha256"; done
    done < <(ls -1 "$dir" | grep -v '\.sha256$' | sed -E 's/_[0-9]{4}-[0-9]{2}-[0-9]{2}_.*$//' | sort -u)
}

# --- copie distante chiffrée (optionnelle) ---------------------------------------
#
# Rattrapage : pour chaque série (sql/www/cfg d'un même nom), la sauvegarde locale la plus récente
# est envoyée si elle manque côté FTP. Un envoi raté une nuit est donc repris la nuit suivante.
# Chaque envoi est vérifié en re-téléchargeant le fichier (sha256), puis un <fichier>.enc.sha256
# (empreinte du fichier CHIFFRÉ) est déposé à côté : à la restauration, vérifier avant de déchiffrer.
offsite() {
    [ -n "$OFFSITE_URL" ] && [ "${SKIP_OFFSITE:-0}" != 1 ] || { log "INFO copie distante désactivée"; return 0; }
    if [ ! -r "$OFFSITE_NETRC" ] || [ ! -r "$OFFSITE_PASSFILE" ]; then
        fail "offsite : $OFFSITE_NETRC ou $OFFSITE_PASSFILE illisible (chiffrement obligatoire)"; return
    fi
    local base=${OFFSITE_URL%/} f name enc size remote list="" old series dir sum dl last age rc latest
    local co=(-sS --fail --netrc-file "$OFFSITE_NETRC" --connect-timeout 20 --max-time 1800)
    local re='^.+_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}\.(sql\.gz|sqlite3\.gz|tar\.gz)\.enc$'
    local strip='s/_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}\..*$//'

    list=$(curl "${co[@]}" -l "$base/" < /dev/null 2> /dev/null); rc=$?
    list=$(printf '%s' "$list" | tr -d '\r')
    if [ "$rc" = 9 ]; then      # dossier distant pas encore créé (tout premier envoi) : il le sera à l'envoi
        log "INFO offsite : dossier distant absent, il sera créé"; list=""
    elif [ "$rc" != 0 ]; then
        fail "offsite : listing distant impossible, curl code $rc (rattrapage et rétention non appliqués)"; list=""
    fi

    # séries à synchroniser : celles de la dernière exécution locale (les anciens noms de containers
    # n'y sont plus) + celles déjà présentes côté FTP (une série qui rate une nuit est donc rattrapée)
    latest=$(ls -1 "$SQL_DIR" "$WWW_DIR" "$CFG_DIR" 2> /dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}' | sort | tail -n 1)
    while read -r series; do
        [ -n "$series" ] || continue
        case $series in
            www_*) dir=$WWW_DIR ;;
            cfg_*) dir=$CFG_DIR ;;
            *)     dir=$SQL_DIR ;;
        esac
        f=$(ls -1t "$dir/${series}"_[0-9][0-9][0-9][0-9]-* 2> /dev/null | grep -v '\.sha256$' | head -n 1)
        [ -n "$f" ] || continue
        name=$(basename "$f")

        # déjà complet côté FTP (archive + empreinte) ?
        # (here-strings et non tubes : avec pipefail, grep -q qui sort tôt donne un faux « absent » par SIGPIPE)
        if grep -qxF "$name.enc" <<< "$list" && grep -qxF "$name.enc.sha256" <<< "$list"; then
            continue
        fi
        # archives www (lourdes) : un jour par semaine, ou dès que la dernière copie distante a >= 7 jours
        case $name in
            www_*)
                if [ "$OFFSITE_WWW_WEEKDAY" != 0 ] && [ "$(date +%u)" != "$OFFSITE_WWW_WEEKDAY" ]; then
                    last=$(printf '%s\n' "$list" | grep -E "^${series}_[0-9]{4}-" | grep -E '\.enc$' | sort | tail -n 1 \
                        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
                    if [ -n "$last" ]; then
                        age=$(( ($(date +%s) - $(date -d "$last" +%s)) / 86400 ))
                        [ "$age" -ge 7 ] || continue
                    fi
                fi ;;
        esac

        enc="$TMP/$name.enc"; dl="$TMP/$name.dl"
        if ! openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass "file:$OFFSITE_PASSFILE" -in "$f" -out "$enc"; then
            fail "offsite $name (chiffrement)"; rm -f "$enc"; continue
        fi
        size=$(stat -c %s "$enc")
        sum=$(sha256sum < "$enc" | cut -d' ' -f1)
        printf '%s  %s\n' "$sum" "$name.enc" > "$enc.sha256"
        if curl "${co[@]}" --ftp-create-dirs -T "$enc" "$base/$name.enc" < /dev/null \
            && remote=$(curl "${co[@]}" -I "$base/$name.enc" < /dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}') \
            && [ "$remote" = "$size" ] \
            && curl "${co[@]}" -o "$dl" "$base/$name.enc" < /dev/null \
            && [ "$(sha256sum < "$dl" | cut -d' ' -f1)" = "$sum" ] \
            && curl "${co[@]}" -T "$enc.sha256" "$base/$name.enc.sha256" < /dev/null; then
            log "OK   offsite $name.enc ($size octets, sha256 revérifié après téléchargement)"
        else
            fail "offsite $name (envoi, taille ou empreinte distante incorrecte)"
        fi
        rm -f "$enc" "$enc.sha256" "$dl"
    done < <({ ls -1 "$SQL_DIR" "$WWW_DIR" "$CFG_DIR" 2> /dev/null | grep -F "_${latest}."
               grep -E "$re" <<< "$list"; } | sed -E "$strip" | sort -u)

    # Rétention distante : ne touche QUE les fichiers *.enc (et leur .sha256) au nom horodaté de ce script.
    # (listing refait : celui du début ne contient pas les envois de cette nuit)
    list=$(curl "${co[@]}" -l "$base/" < /dev/null 2> /dev/null) && list=$(printf '%s' "$list" | tr -d '\r') || list=""
    if [ -n "$list" ]; then
        grep -E "$re" <<< "$list" | sort -r \
            | awk -v keep="$OFFSITE_KEEP" '{ s=$0; sub(/_20[0-9][0-9]-.*$/, "", s); if (++n[s] > keep) print }' \
            | while read -r old; do
                curl "${co[@]}" -Q "-DELE $old" -o /dev/null "$base/" < /dev/null && log "DEL  offsite $old (rétention)"
                if grep -qxF "$old.sha256" <<< "$list"; then
                    curl "${co[@]}" -Q "-DELE $old.sha256" -o /dev/null "$base/" < /dev/null || true
                fi
            done
    fi
}

# =============================================================================
log "=== Sauvegarde $STAMP ==="

# OFFSITE_ONLY=1 : ne refait aucune archive, reprend seulement les envois distants manquants
if [ "${OFFSITE_ONLY:-0}" = 1 ]; then
    offsite
    log "=== Rattrapage copie distante terminé : $FAILS échec(s) ==="
    [ "$FAILS" -eq 0 ]; exit $?
fi

free_gb=$(df --output=avail -BG "$BACKUP_ROOT" | tail -n 1 | tr -dc '0-9')
if [ "${free_gb:-0}" -lt "$MIN_FREE_GB" ]; then
    fail "espace disque insuffisant (${free_gb:-?} Go libres, $MIN_FREE_GB requis)"
    exit 1
fi
find "$SQL_DIR" "$WWW_DIR" "$CFG_DIR" -name '*.part' -mmin +60 -delete

backup_db portfolio_wp db-portfolio db-wp
backup_db dc_database  db-dotclear db-blog
for ct in tinyauth beszel upsnap pocketbase; do backup_app "$ct"; done

backup_www portfolio portfolio
backup_www dotclear  dotclear  blog
backup_www brasserie brasserie

backup_cfg_host
for ct in $(lxc-ls --running); do backup_cfg_ct "$ct"; done

prune_dir "$SQL_DIR" "$KEEP_SQL"
prune_dir "$WWW_DIR" "$KEEP_WWW"
prune_dir "$CFG_DIR" "$KEEP_CFG"
if [ "$FAILS" -eq 0 ]; then
    # séries orphelines (ex. anciens noms de containers) : elles vieillissent puis disparaissent
    find "$SQL_DIR" "$WWW_DIR" "$CFG_DIR" -type f -mtime +"$MAX_AGE_DAYS" -delete
fi

offsite

log "=== Sauvegarde $STAMP terminée : ${#NEWFILES[@]} archives, $FAILS échec(s), $(du -sh "$BACKUP_ROOT" | cut -f1) au total ==="
# le marqueur d'échec (posé par backup-portfolio-failed.service) disparaît dès qu'une nuit se passe bien
[ "$FAILS" -eq 0 ] && [ "${BACKUP_ROOT}" = /root/backups ] && rm -f /root/BACKUP_ECHEC.txt
[ "$FAILS" -eq 0 ]

# -----------------------------------------------------------------------------
# Exemple de /etc/backup_portfolio.conf (root:root, chmod 600) pour la copie distante :
#   OFFSITE_URL="ftp://ftp.example.org/backups_vps/"
#   # /root/.netrc.backup (chmod 600) :  machine ftp.example.org login <identifiant> password <mot de passe>
#   # /root/.backup_passphrase (chmod 600) : longue phrase secrète. SANS ELLE les copies distantes
#   # sont illisibles : conservez-en un exemplaire ailleurs (gestionnaire de mots de passe).
#   # Restauration : sha256sum -c fichier.tar.gz.enc.sha256   (les deux fichiers téléchargés dans le même dossier)
#   #                openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass file:/root/.backup_passphrase \
#   #                  -in fichier.tar.gz.enc -out fichier.tar.gz
#   # Rattrapage manuel des envois manquants : OFFSITE_ONLY=1 /usr/local/sbin/backup_portfolio.sh
#   # Échec de la sauvegarde : /root/BACKUP_ECHEC.txt + entrée syslog "backup-portfolio" (unité en échec dans Cockpit).
# -----------------------------------------------------------------------------
