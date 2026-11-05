#!/bin/bash

# ============================================================
# Projet XTI302-CYB - Laboratoire BioLab
# Script : analyse_logs.sh
# Objectif : rapport d'analyse des journaux SSH (J4)
# Installation prévue : /usr/local/sbin/analyse_logs.sh (root:root 0755)
# Configuration       : /etc/biolab/analyse_logs.conf  (root:root 0644)
# ============================================================
#
# Usage :
#   sudo /usr/local/sbin/analyse_logs.sh
#       Mode nominal (root, via sudo) : AUCUN argument accepté.
#       Seuil, période et source sont lus dans /etc/biolab/analyse_logs.conf.
#
#   analyse_logs.sh -f FICHIER [-s SEUIL]
#       Mode hors ligne, réservé aux utilisateurs NON root : analyse un
#       export de journal que l'appelant peut déjà lire avec ses propres
#       droits (aucune élévation de privilège possible).
#
#   analyse_logs.sh -h
#
# Codes de retour :
#   0  analyse terminée, aucune adresse IP n'atteint le seuil
#   1  ALERTE : au moins une adresse IP atteint le seuil d'échecs
#   2  erreur d'utilisation (argument invalide ou refusé)
#   3  dépendance manquante
#   4  privilèges insuffisants
#   5  configuration invalide ou non sécurisée
#   6  source de journaux indisponible
#   70 erreur interne inattendue
#
# Le script est en lecture seule : il ne modifie aucune configuration,
# n'écrit aucun fichier hors de son répertoire temporaire privé (supprimé
# en fin d'exécution) et ne supprime aucun journal.
# ============================================================

set -Eeuo pipefail
shopt -s inherit_errexit

readonly E_OK=0
readonly E_ALERTE=1
readonly E_USAGE=2
readonly E_DEPENDANCE=3
readonly E_PRIVILEGES=4
readonly E_CONFIG=5
readonly E_SOURCE=6
readonly E_INTERNE=70

# En contexte privilégié, l'environnement de l'appelant n'est pas fiable :
# PATH maîtrisé (identique au secure_path de sudo sous Debian).
if [[ "$EUID" -eq 0 ]]; then
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    export PATH
fi
IFS=$' \t\n'
umask 077
export LC_ALL=C

# Emplacements fixes : jamais modifiables par argument ou par variable
# d'environnement.
CONFIG_FILE="/etc/biolab/analyse_logs.conf"
AUTHLOG_FILE="/var/log/auth.log"
SSH_UNIT="ssh.service"

# Valeurs par défaut (surchargées par le fichier de configuration).
SEUIL_ECHECS_IP=5
PERIODE="24h"
SOURCE="auto"
NB_LIGNES_MAX=10

# État interne.
FICHIER=""
SEUIL_CLI=""
AIDE=0
REP_TMP=""
SOURCE_UTILISEE=""
PERIODE_AFFICHEE=""
RESULTAT=$E_OK
TAB=$'\t'
declare -a REMARQUES=()

# ------------------------------------------------------------
# Messages et sortie
# ------------------------------------------------------------

erreur() {
    echo "ERREUR : $*" >&2
}

echouer() {
    local code="$1"
    shift
    erreur "$*"
    exit "$code"
}

remarque() {
    REMARQUES+=("$*")
    echo "AVERTISSEMENT : $*" >&2
}

erreur_interne() {
    local ligne="$1" code="$2"
    trap - ERR
    erreur "erreur interne inattendue (ligne $ligne, code $code)."
    exit "$E_INTERNE"
}

nettoyer() {
    # Ne supprime que le répertoire temporaire créé par ce script.
    if [[ -n "$REP_TMP" && -d "$REP_TMP" ]]; then
        rm -rf -- "$REP_TMP"
    fi
}

# Neutralise les caractères non imprimables (séquences d'échappement
# terminal) d'une chaîne fournie par l'appelant avant affichage.
assainir() {
    local texte="$1"
    printf '%s' "${texte//[^[:print:]]/?}"
}

afficher_aide() {
    cat <<'EOF'
analyse_logs.sh - rapport d'analyse des journaux SSH (BioLab, J4)

Usage :
  sudo /usr/local/sbin/analyse_logs.sh     mode nominal, sans argument
  analyse_logs.sh -f FICHIER [-s SEUIL]    mode hors ligne (non root uniquement)
  analyse_logs.sh -h                       cette aide

Configuration : /etc/biolab/analyse_logs.conf (CLE=valeur)
  SEUIL_ECHECS_IP=5    alerte si une IP atteint ce nombre d'échecs (1-100000)
  PERIODE=24h          fenêtre analysée : Nh, Nd (N de 1 à 9999) ou "tout"
  SOURCE=auto          auto | journald | authlog
  NB_LIGNES_MAX=10     lignes affichées par classement (1-100)

Codes de retour : 0 OK, 1 seuil atteint, 2 usage, 3 dépendance,
4 privilèges, 5 configuration, 6 source indisponible, 70 erreur interne.
EOF
}

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------

entier_entre() {
    local valeur="$1" min="$2" max="$3"
    [[ "$valeur" =~ ^[0-9]{1,6}$ ]] || return 1
    (( 10#$valeur >= min && 10#$valeur <= max ))
}

periode_valide() {
    [[ "$1" == "tout" || "$1" =~ ^[1-9][0-9]{0,3}[hd]$ ]]
}

# ------------------------------------------------------------
# Arguments
# ------------------------------------------------------------

analyser_arguments() {
    # Contexte privilégié : interface fermée. Tout réglage passe par le
    # fichier de configuration appartenant à root.
    if [[ "$EUID" -eq 0 && $# -gt 0 ]]; then
        if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
            AIDE=1
            return 0
        fi
        echouer "$E_USAGE" "en exécution root (sudo), aucun argument n'est accepté." \
            "Le seuil se règle dans $CONFIG_FILE."
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                AIDE=1
                return 0
                ;;
            -f)
                [[ $# -ge 2 ]] || echouer "$E_USAGE" "l'option -f attend un fichier."
                [[ -z "$FICHIER" ]] || echouer "$E_USAGE" "l'option -f ne peut être donnée qu'une fois."
                FICHIER="$2"
                shift 2
                ;;
            -s)
                [[ $# -ge 2 ]] || echouer "$E_USAGE" "l'option -s attend un entier."
                entier_entre "$2" 1 100000 \
                    || echouer "$E_USAGE" "seuil invalide : $(assainir "$2") (entier de 1 à 100000)."
                SEUIL_CLI="$((10#$2))"
                shift 2
                ;;
            *)
                echouer "$E_USAGE" "argument non reconnu : $(assainir "$1") (voir -h)."
                ;;
        esac
    done

    if [[ -n "$SEUIL_CLI" && -z "$FICHIER" ]]; then
        echouer "$E_USAGE" "l'option -s n'est utilisable qu'avec -f (mode hors ligne)."
    fi
}

# ------------------------------------------------------------
# Prérequis
# ------------------------------------------------------------

verifier_privileges() {
    # La lecture complète du journal système (y compris les messages
    # d'authentification) nécessite root.
    if [[ "$EUID" -ne 0 ]]; then
        echouer "$E_PRIVILEGES" "la lecture des journaux système nécessite root :" \
            "sudo /usr/local/sbin/analyse_logs.sh"
    fi
}

verifier_dependances() {
    local -a absents=()
    local outil

    for outil in "$@"; do
        if ! command -v "$outil" >/dev/null 2>&1; then
            absents+=("$outil")
        fi
    done

    if [[ ${#absents[@]} -gt 0 ]]; then
        echouer "$E_DEPENDANCE" "commande(s) requise(s) absente(s) : ${absents[*]}"
    fi
}

# ------------------------------------------------------------
# Configuration : format CLE=valeur, lu ligne à ligne et validé.
# Le fichier n'est JAMAIS exécuté (pas de source / eval).
# ------------------------------------------------------------

charger_configuration() {
    local fichier="$1"
    local ligne cle valeur proprio droits
    local num=0

    if [[ ! -e "$fichier" ]]; then
        remarque "configuration $fichier absente : valeurs par défaut utilisées."
        return 0
    fi

    if [[ ! -f "$fichier" || ! -r "$fichier" ]]; then
        echouer "$E_CONFIG" "configuration $fichier illisible ou n'est pas un fichier."
    fi

    # Exécuté en root : la configuration doit appartenir à root et ne pas
    # être modifiable par un groupe ou par les autres utilisateurs.
    if [[ "$EUID" -eq 0 ]]; then
        proprio="$(stat -L -c '%u' -- "$fichier")"
        droits="$(stat -L -c '%a' -- "$fichier")"
        if [[ "$proprio" != "0" ]] || (( (8#$droits & 8#022) != 0 )); then
            echouer "$E_CONFIG" "configuration $fichier non sécurisée" \
                "(propriétaire uid=$proprio, droits $droits ; attendu root, 0644 ou plus strict)."
        fi
    fi

    while IFS= read -r ligne || [[ -n "$ligne" ]]; do
        num=$((num + 1))
        ligne="${ligne%$'\r'}"

        if [[ "$ligne" =~ ^[[:space:]]*(#.*)?$ ]]; then
            continue
        fi

        if [[ ! "$ligne" =~ ^([A-Z_]+)=([A-Za-z0-9]*)$ ]]; then
            echouer "$E_CONFIG" "$fichier ligne $num : format attendu CLE=valeur (lettres et chiffres)."
        fi
        cle="${BASH_REMATCH[1]}"
        valeur="${BASH_REMATCH[2]}"

        case "$cle" in
            SEUIL_ECHECS_IP)
                entier_entre "$valeur" 1 100000 \
                    || echouer "$E_CONFIG" "$fichier ligne $num : SEUIL_ECHECS_IP doit être un entier de 1 à 100000."
                SEUIL_ECHECS_IP="$((10#$valeur))"
                ;;
            PERIODE)
                periode_valide "$valeur" \
                    || echouer "$E_CONFIG" "$fichier ligne $num : PERIODE doit valoir Nh, Nd (N de 1 à 9999) ou tout."
                PERIODE="$valeur"
                ;;
            SOURCE)
                case "$valeur" in
                    auto|journald|authlog) SOURCE="$valeur" ;;
                    *) echouer "$E_CONFIG" "$fichier ligne $num : SOURCE doit valoir auto, journald ou authlog." ;;
                esac
                ;;
            NB_LIGNES_MAX)
                entier_entre "$valeur" 1 100 \
                    || echouer "$E_CONFIG" "$fichier ligne $num : NB_LIGNES_MAX doit être un entier de 1 à 100."
                NB_LIGNES_MAX="$((10#$valeur))"
                ;;
            *)
                echouer "$E_CONFIG" "$fichier ligne $num : clé inconnue $cle."
                ;;
        esac
    done < "$fichier"
}

# ------------------------------------------------------------
# Collecte
# ------------------------------------------------------------

# Écrit dans les variables globales DEPUIS_JOURNALCTL et DEPUIS_ISO la date
# de début de la fenêtre d'analyse (vides si PERIODE=tout).
calculer_fenetre() {
    local nombre unite
    DEPUIS_JOURNALCTL=""
    DEPUIS_ISO=""

    if [[ "$PERIODE" == "tout" ]]; then
        PERIODE_AFFICHEE="intégralité des journaux disponibles"
        return 0
    fi

    nombre="${PERIODE%[hd]}"
    case "${PERIODE: -1}" in
        h) unite="hours" ;;
        d) unite="days" ;;
    esac

    DEPUIS_ISO="$(date -d "-$nombre $unite" '+%Y-%m-%dT%H:%M:%S')"
    DEPUIS_JOURNALCTL="${DEPUIS_ISO/T/ }"
    PERIODE_AFFICHEE="depuis $DEPUIS_JOURNALCTL ($PERIODE)"
}

# journald : filtrage sur l'unité ssh.service (champ _SYSTEMD_UNIT, attribué
# par journald d'après le cgroup). Un filtre par identifiant (-t) serait
# falsifiable par n'importe quel utilisateur local via logger(1).
collecter_journald() {
    local sortie="$1" erreurs="$2"
    local -a options=(--no-pager --quiet --output=short-iso -u "$SSH_UNIT")

    if [[ -n "$DEPUIS_JOURNALCTL" ]]; then
        options+=(--since "$DEPUIS_JOURNALCTL")
    fi

    journalctl "${options[@]}" >"$sortie" 2>"$erreurs"
}

authlog_disponible() {
    [[ -f "$AUTHLOG_FILE" && -r "$AUTHLOG_FILE" && -s "$AUTHLOG_FILE" ]]
}

# ------------------------------------------------------------
# Extraction des événements (awk POSIX, compatible mawk de Debian)
#
# Sortie : une ligne par événement, séparateur tabulation
#   F <ip> <compte> <inexistant:0|1>       un échec d'authentification
#   A <horodatage> <compte> <ip> <méthode>  une connexion réussie
#   L <nombre de lignes SSH lues>
#
# Règles de comptage (une connexion = un PID sshd-session + une IP) :
#   - chaque ligne "Failed <méthode> for ..." compte pour un échec ;
#   - une connexion sans "Failed" ni "Accepted" mais refusée avant
#     authentification (Invalid user, compte hors AllowGroups, fermeture
#     [preauth] d'un utilisateur en cours d'authentification, nombre
#     maximal d'essais) compte pour un échec ;
#   - les lignes PAM et les lignes redondantes d'une même connexion ne
#     sont pas recomptées.
# ------------------------------------------------------------

extraire_evenements() {
    local entree="$1" sortie="$2" depuis="$3"

    awk -v depuis="$depuis" '
    function nettoyer(s) {
        gsub(/[^A-Za-z0-9._@+-]/, "?", s)
        if (length(s) > 32) s = substr(s, 1, 32) "~"
        if (s == "") s = "(vide)"
        return s
    }
    function ip_valide(s) {
        if (s ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return 1
        if (s ~ /^[0-9A-Fa-f:.]+$/ && index(s, ":") > 0) return 1
        return 0
    }
    function joindre(debut, fin,    i, r) {
        r = ""
        for (i = debut; i <= fin; i++) r = (r == "") ? w[i] : (r " " w[i])
        return r
    }
    function indice_from(    k) {
        for (k = n - 1; k >= 1; k--) if (w[k] == "from" && ip_valide(w[k + 1])) return k
        return 0
    }
    function indice_ip_port(    k) {
        for (k = n - 1; k >= 1; k--) if (w[k + 1] == "port" && ip_valide(w[k])) return k
        return 0
    }
    function refus(cle, ip, compte, inexistant) {
        vu[cle] = 1
        cip[cle] = ip
        if (!(cle in ccompte)) ccompte[cle] = compte
        if (inexistant) cinex[cle] = 1
    }
    {
        if (depuis != "" && $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ && substr($1, 1, 19) < depuis) next
        if (!match($0, /sshd(-session|-auth)?\[[0-9]+\]: /)) next
        lignes++
        entete = substr($0, RSTART, RLENGTH)
        msg = substr($0, RSTART + RLENGTH)
        pid = entete
        sub(/^[^[]*\[/, "", pid)
        sub(/\].*$/, "", pid)
        horo = ($1 ~ /^[0-9]/) ? $1 : ($1 " " $2 " " $3)
        sub(/^(error|fatal): (PAM: )?/, "", msg)
        n = split(msg, w, " ")
        if (n < 3) next

        if (w[1] == "Accepted" && w[3] == "for") {
            k = indice_from()
            if (k < 5) next
            ip = w[k + 1]
            accepte[pid SUBSEP ip] = 1
            print "A\t" horo "\t" nettoyer(joindre(4, k - 1)) "\t" ip "\t" nettoyer(w[2])
        } else if (w[1] == "Failed" && w[3] == "for") {
            k = indice_from()
            if (k == 0) next
            ip = w[k + 1]
            inex = (w[4] == "invalid" && w[5] == "user") ? 1 : 0
            echec[pid SUBSEP ip] = 1
            print "F\t" ip "\t" nettoyer(joindre(inex ? 6 : 4, k - 1)) "\t" inex
        } else if (w[1] == "Invalid" && w[2] == "user") {
            k = indice_from()
            if (k == 0) next
            refus(pid SUBSEP w[k + 1], w[k + 1], nettoyer(joindre(3, k - 1)), 1)
        } else if (w[1] == "User" && index(msg, " not allowed because ") > 0) {
            k = indice_from()
            if (k == 0) next
            refus(pid SUBSEP w[k + 1], w[k + 1], nettoyer(joindre(2, k - 1)), 1)
        } else if ((w[1] == "Connection" && w[2] == "closed" && w[3] == "by") || (w[1] == "Disconnected" && w[2] == "from")) {
            d = (w[1] == "Connection") ? 4 : 3
            if ((w[d] != "invalid" && w[d] != "authenticating") || w[d + 1] != "user") next
            if (msg !~ /\[preauth\]$/) next
            k = indice_ip_port()
            if (k == 0) next
            refus(pid SUBSEP w[k], w[k], nettoyer(joindre(d + 2, k - 1)), (w[d] == "invalid") ? 1 : 0)
        } else if (index(msg, "maximum authentication attempts exceeded for ") == 1) {
            k = indice_from()
            if (k == 0) next
            inex = (w[6] == "invalid" && w[7] == "user") ? 1 : 0
            refus(pid SUBSEP w[k + 1], w[k + 1], nettoyer(joindre(inex ? 8 : 6, k - 1)), inex)
        }
    }
    END {
        for (cle in vu)
            if (!(cle in echec) && !(cle in accepte))
                print "F\t" cip[cle] "\t" ccompte[cle] "\t" ((cle in cinex) ? 1 : 0)
        print "L\t" (lignes + 0)
    }
    ' "$entree" > "$sortie"
}

nombre_lignes_ssh() {
    awk -F'\t' '$1 == "L" { print $2 }' "$1"
}

# ------------------------------------------------------------
# Rapport
# ------------------------------------------------------------

titre() {
    printf '\n--- %s ---\n' "$1"
}

info() {
    printf '%s: %s\n' "$1" "$2"
}

generer_rapport() {
    local evts="$1"
    local par_ip="$REP_TMP/par_ip" par_compte="$REP_TMP/par_compte"
    local reussites="$REP_TMP/reussites" alertes="$REP_TMP/alertes"
    local nb_lignes nb_echecs nb_ip nb_comptes nb_reussites nb_mdp nb_alertes
    local liste_alertes r

    awk -F'\t' '$1 == "F" { c[$2]++ } END { for (i in c) print c[i] "\t" i }' "$evts" \
        | sort -t "$TAB" -k1,1nr -k2,2 > "$par_ip"
    awk -F'\t' '$1 == "F" { c[$3]++; if ($4 == 1) x[$3] = 1 }
        END { for (u in c) print c[u] "\t" u "\t" ((u in x) ? 1 : 0) }' "$evts" \
        | sort -t "$TAB" -k1,1nr -k2,2 > "$par_compte"
    awk -F'\t' '$1 == "A" { c[$3 "\t" $4 "\t" $5]++ } END { for (k in c) print c[k] "\t" k }' "$evts" \
        | sort -t "$TAB" -k1,1nr -k2,2 > "$reussites"
    awk -F'\t' -v s="$SEUIL_ECHECS_IP" '$1 >= s { print $2 }' "$par_ip" > "$alertes"

    nb_lignes="$(nombre_lignes_ssh "$evts")"
    nb_echecs="$(awk -F'\t' '$1 == "F" { c++ } END { print c + 0 }' "$evts")"
    nb_ip="$(awk 'END { print NR }' "$par_ip")"
    nb_comptes="$(awk 'END { print NR }' "$par_compte")"
    nb_reussites="$(awk -F'\t' '$1 == "A" { c++ } END { print c + 0 }' "$evts")"
    nb_mdp="$(awk -F'\t' '$1 == "A" && $5 == "password" { c++ } END { print c + 0 }' "$evts")"
    nb_alertes="$(awk 'END { print NR }' "$alertes")"
    liste_alertes="$(awk '{ printf "%s%s", (NR > 1 ? " " : ""), $0 }' "$alertes")"

    echo "=============================================================="
    echo " RAPPORT D'ANALYSE DES JOURNAUX SSH - BioLab (J4)"
    echo "=============================================================="
    # Libellés alignés à la main : sous LC_ALL=C, printf compte les octets
    # et décalerait les libellés accentués.
    info "Machine                 " "$(uname -n)"
    info "Date du rapport         " "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    info "Source                  " "$SOURCE_UTILISEE"
    info "Période                 " "$PERIODE_AFFICHEE"
    info "Seuil d'alerte          " "$SEUIL_ECHECS_IP échecs par adresse IP"
    info "Lignes SSH analysées    " "$nb_lignes"

    if [[ "$nb_lignes" -eq 0 ]]; then
        echo
        echo "Aucun événement SSH trouvé sur la période analysée."
    fi

    titre "1. Tentatives de connexion échouées"
    printf 'Total : %s échec(s), depuis %s adresse(s) IP, visant %s compte(s).\n' \
        "$nb_echecs" "$nb_ip" "$nb_comptes"

    titre "2. Adresses IP sources des échecs (${NB_LIGNES_MAX} premières)"
    if [[ "$nb_ip" -eq 0 ]]; then
        echo "  (aucune)"
    else
        printf '  ÉCHECS  %-39s %s\n' "ADRESSE IP" "ÉTAT"
        awk -F'\t' -v max="$NB_LIGNES_MAX" -v s="$SEUIL_ECHECS_IP" \
            'NR <= max { printf "  %6d  %-39s %s\n", $1, $2, ($1 >= s ? "SEUIL ATTEINT" : "") }' "$par_ip"
    fi

    titre "3. Comptes ciblés par les échecs (${NB_LIGNES_MAX} premiers)"
    if [[ "$nb_comptes" -eq 0 ]]; then
        echo "  (aucun)"
    else
        printf '  ÉCHECS  %-34s %s\n' "COMPTE" "REMARQUE"
        awk -F'\t' -v max="$NB_LIGNES_MAX" \
            'NR <= max { printf "  %6d  %-34s %s\n", $1, $2, ($3 == 1 ? "inexistant ou non autorisé" : "") }' "$par_compte"
    fi

    titre "4. Connexions SSH réussies"
    printf 'Total : %s connexion(s) réussie(s), dont %s par mot de passe.\n' "$nb_reussites" "$nb_mdp"
    if [[ "$nb_reussites" -gt 0 ]]; then
        printf '  %6s  %-24s %-39s %s\n' "NOMBRE" "COMPTE" "ADRESSE IP" "MÉTHODE"
        awk -F'\t' -v max="$NB_LIGNES_MAX" \
            'NR <= max { printf "  %6d  %-24s %-39s %s\n", $1, $2, $3, $4 }' "$reussites"
        echo "Dernières connexions réussies :"
        awk -F'\t' '$1 == "A"' "$evts" | tail -n "$NB_LIGNES_MAX" \
            | awk -F'\t' '{ printf "  %s  %s depuis %s (%s)\n", $2, $3, $4, $5 }'
    fi

    if [[ ${#REMARQUES[@]} -gt 0 ]]; then
        titre "Remarques"
        for r in "${REMARQUES[@]}"; do
            echo "  - $r"
        done
    fi

    titre "5. Bilan synthétique"
    info "Échecs d'authentification   " "$nb_echecs ($nb_ip adresse(s) IP, $nb_comptes compte(s))"
    info "Connexions réussies         " "$nb_reussites (dont $nb_mdp par mot de passe)"
    info "Seuil par adresse IP        " "$SEUIL_ECHECS_IP"
    if [[ "$nb_alertes" -gt 0 ]]; then
        RESULTAT=$E_ALERTE
        info "Résultat                    " "ALERTE - $nb_alertes adresse(s) IP atteignent le seuil : $liste_alertes"
    else
        RESULTAT=$E_OK
        info "Résultat                    " "OK - aucune adresse IP n'atteint le seuil"
    fi
    info "Code de retour              " "$RESULTAT"
}

# ------------------------------------------------------------
# Programme principal
# ------------------------------------------------------------

main() {
    local brut evts erreurs premiere_erreur

    trap 'erreur_interne "$LINENO" "$?"' ERR
    trap nettoyer EXIT

    analyser_arguments "$@"
    if [[ "$AIDE" -eq 1 ]]; then
        afficher_aide
        exit "$E_OK"
    fi

    if [[ -z "$FICHIER" ]]; then
        verifier_privileges
    fi

    verifier_dependances awk sort tail date uname mktemp stat rm
    charger_configuration "$CONFIG_FILE"
    if [[ -z "$FICHIER" && "$SOURCE" != "authlog" ]]; then
        verifier_dependances journalctl
    fi

    if [[ -n "$SEUIL_CLI" ]]; then
        SEUIL_ECHECS_IP="$SEUIL_CLI"
    fi

    if [[ "$EUID" -eq 0 ]]; then
        REP_TMP="$(mktemp -d /tmp/analyse_logs.XXXXXXXX)"
    else
        REP_TMP="$(mktemp -d -t analyse_logs.XXXXXXXX)"
    fi
    evts="$REP_TMP/evenements"
    erreurs="$REP_TMP/erreurs"

    # Mode hors ligne : fichier fourni par un utilisateur non root.
    if [[ -n "$FICHIER" ]]; then
        if [[ ! -f "$FICHIER" || ! -r "$FICHIER" ]]; then
            echouer "$E_SOURCE" "fichier illisible ou n'est pas un fichier régulier : $(assainir "$FICHIER")"
        fi
        PERIODE_AFFICHEE="intégralité du fichier (période non appliquée)"
        SOURCE_UTILISEE="fichier $(assainir "$FICHIER")"
        extraire_evenements "$FICHIER" "$evts" ""
        generer_rapport "$evts"
        exit "$RESULTAT"
    fi

    calculer_fenetre

    if [[ "$SOURCE" != "authlog" ]]; then
        brut="$REP_TMP/journald"
        if collecter_journald "$brut" "$erreurs"; then
            SOURCE_UTILISEE="journald (unité $SSH_UNIT)"
            extraire_evenements "$brut" "$evts" ""
        else
            premiere_erreur="$(awk 'NR == 1' "$erreurs")"
            if [[ "$SOURCE" == "auto" ]] && authlog_disponible; then
                remarque "journalctl a échoué ($(assainir "$premiere_erreur")) : repli sur $AUTHLOG_FILE."
            else
                echouer "$E_SOURCE" "lecture du journal systemd impossible : $(assainir "$premiere_erreur")"
            fi
        fi
    fi

    # Repli sur auth.log (rsyslog) si demandé, ou en mode auto lorsque
    # journald ne contient aucune ligne SSH (journal non persistant après
    # redémarrage, par exemple). Les deux sources ne sont jamais
    # additionnées, pour ne pas compter deux fois le même événement.
    if [[ "$SOURCE" == "authlog" ]] \
        || { [[ "$SOURCE" == "auto" ]] && { [[ -z "$SOURCE_UTILISEE" ]] \
            || [[ "$(nombre_lignes_ssh "$evts")" -eq 0 ]]; } && authlog_disponible; }; then
        if ! authlog_disponible; then
            echouer "$E_SOURCE" "$AUTHLOG_FILE absent, vide ou illisible (rsyslog installé ?)."
        fi
        if [[ -n "$SOURCE_UTILISEE" ]]; then
            remarque "aucune ligne SSH dans journald sur la période : repli sur $AUTHLOG_FILE."
        fi
        SOURCE_UTILISEE="$AUTHLOG_FILE (fichier courant, sans les archives tournées)"
        extraire_evenements "$AUTHLOG_FILE" "$evts" "$DEPUIS_ISO"
    fi

    generer_rapport "$evts"
    exit "$RESULTAT"
}

# Exécution directe uniquement : le chargement par "source" (tests
# unitaires) ne lance pas l'analyse.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
