#!/bin/bash

# ============================================================
# Projet XTI302-CYB - Laboratoire BioLab
# Script : tests/test_analyse_logs.sh
# Objectif : tests reproductibles de analyse_logs.sh (J4)
# ============================================================
#
# Usage : bash tests/test_analyse_logs.sh   (utilisateur NON root)
#
# Les journaux de test sont générés dans un répertoire temporaire à partir
# de lignes au format Debian 13 (journalctl -o short-iso, sshd-session).
# Aucun accès au journal système, aucune modification du système.

set -Euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CIBLE="$SCRIPT_DIR/../analyse_logs.sh"
BASH_BIN="$(command -v bash)"
REP=""
REUSSIS=0
ECHOUES=0

if [[ "$EUID" -eq 0 ]]; then
    echo "ERREUR : lancer ces tests avec un utilisateur non root" >&2
    echo "(en root, le script refuse volontairement tout argument)." >&2
    exit 2
fi

if [[ ! -f "$CIBLE" ]]; then
    echo "ERREUR : analyse_logs.sh introuvable ($CIBLE)." >&2
    exit 2
fi

REP="$(mktemp -d -t test_analyse_logs.XXXXXXXX)"
trap 'rm -rf -- "$REP"' EXIT

# ------------------------------------------------------------
# Outils de test
# ------------------------------------------------------------

SORTIE=""
CODE=0

# Exécute analyse_logs.sh ; stdout+stderr dans SORTIE, code dans CODE.
lancer() {
    SORTIE="$("$BASH_BIN" "$CIBLE" "$@" 2>&1)" && CODE=0 || CODE=$?
}

ok() {
    REUSSIS=$((REUSSIS + 1))
    printf '  [OK]    %s\n' "$1"
}

ko() {
    ECHOUES=$((ECHOUES + 1))
    printf '  [ECHEC] %s\n' "$1"
    if [[ -n "${2:-}" ]]; then
        printf '          %s\n' "$2"
    fi
}

verifier_code() {
    local attendu="$1" libelle="$2"
    if [[ "$CODE" -eq "$attendu" ]]; then
        ok "$libelle (code $CODE)"
    else
        ko "$libelle" "code obtenu $CODE, attendu $attendu. Sortie : ${SORTIE:0:300}"
    fi
}

verifier_motif() {
    local motif="$1" libelle="$2"
    if [[ "$SORTIE" =~ $motif ]]; then
        ok "$libelle"
    else
        ko "$libelle" "motif absent : $motif"
    fi
}

verifier_absence() {
    local motif="$1" libelle="$2"
    if [[ "$SORTIE" =~ $motif ]]; then
        ko "$libelle" "motif présent : $motif"
    else
        ok "$libelle"
    fi
}

# ------------------------------------------------------------
# Jeux de données (format Debian 13 réel, voir état des lieux)
# ------------------------------------------------------------

H="Debian13-BioLab"

cat > "$REP/sans_echec.log" <<EOF
2026-11-04T14:42:56+01:00 $H sshd[800]: Server listening on 0.0.0.0 port 22.
2026-11-04T14:43:22+01:00 $H sshd-session[5225]: Accepted password for biolab-admin from 192.168.122.1 port 41210 ssh2
2026-11-04T14:43:22+01:00 $H sshd-session[5225]: pam_unix(sshd:session): session opened for user biolab-admin(uid=1000) by biolab-admin(uid=0)
EOF

ESC=$'\033'
{
    # 203.0.113.45 : 6 connexions, 6 échecs (admin x3, root, oracle, test).
    # Chaque connexion « invalid user » produit plusieurs lignes : 1 échec.
    p=2001
    for u in admin admin oracle test admin; do
        echo "2026-11-04T03:12:0${p: -1}+01:00 $H sshd-session[$p]: Invalid user $u from 203.0.113.45 port 4102$((p % 10))"
        echo "2026-11-04T03:12:0${p: -1}+01:00 $H sshd-session[$p]: pam_unix(sshd:auth): check pass; user unknown"
        echo "2026-11-04T03:12:0${p: -1}+01:00 $H sshd-session[$p]: pam_unix(sshd:auth): authentication failure; logname= uid=0 euid=0 tty=ssh ruser= rhost=203.0.113.45"
        echo "2026-11-04T03:12:0${p: -1}+01:00 $H sshd-session[$p]: Failed password for invalid user $u from 203.0.113.45 port 4102$((p % 10)) ssh2"
        echo "2026-11-04T03:12:0${p: -1}+01:00 $H sshd-session[$p]: Connection closed by invalid user $u 203.0.113.45 port 4102$((p % 10)) [preauth]"
        p=$((p + 1))
    done
    echo "2026-11-04T03:13:00+01:00 $H sshd-session[2006]: Failed password for root from 203.0.113.45 port 41030 ssh2"
    echo "2026-11-04T03:13:00+01:00 $H sshd-session[2006]: Connection closed by authenticating user root 203.0.113.45 port 41030 [preauth]"

    # 198.51.100.23 : 3 mots de passe faux sur support (même connexion)
    # + chercheur1 hors AllowGroups = 4 échecs.
    for i in 1 2 3; do
        echo "2026-11-04T04:00:0$i+01:00 $H sshd-session[2101]: Failed password for support from 198.51.100.23 port 40001 ssh2"
    done
    echo "2026-11-04T04:00:04+01:00 $H sshd-session[2101]: error: maximum authentication attempts exceeded for support from 198.51.100.23 port 40001 ssh2 [preauth]"
    echo "2026-11-04T04:00:04+01:00 $H sshd-session[2101]: PAM 2 more authentication failures; logname= uid=0 euid=0 tty=ssh ruser= rhost=198.51.100.23  user=support"
    echo "2026-11-04T04:01:00+01:00 $H sshd-session[2102]: User chercheur1 from 198.51.100.23 not allowed because none of user's groups are listed in AllowGroups"
    echo "2026-11-04T04:01:00+01:00 $H sshd-session[2102]: Failed password for invalid user chercheur1 from 198.51.100.23 port 40002 ssh2"

    # 192.0.2.7 : compte inexistant, aucune ligne Failed (robot sans mot de passe).
    echo "2026-11-04T05:00:00+01:00 $H sshd-session[2201]: Invalid user guest from 192.0.2.7 port 50000"
    echo "2026-11-04T05:00:00+01:00 $H sshd-session[2201]: Connection closed by invalid user guest 192.0.2.7 port 50000 [preauth]"

    # IPv6.
    echo "2026-11-04T05:10:00+01:00 $H sshd-session[2301]: Failed password for invalid user ubuntu from 2001:db8::5 port 5555 ssh2"

    # Nom d'utilisateur hostile contenant une séquence d'échappement terminal.
    echo "2026-11-04T05:20:00+01:00 $H sshd-session[2401]: Invalid user ${ESC}[31mevil from 203.0.113.99 port 6000"

    # Faute de frappe puis succès sur la même connexion : 1 échec + 1 succès.
    echo "2026-11-04T09:00:00+01:00 $H sshd-session[2501]: Failed password for hugo.boukria from 192.168.122.1 port 41000 ssh2"
    echo "2026-11-04T09:00:05+01:00 $H sshd-session[2501]: Accepted password for hugo.boukria from 192.168.122.1 port 41000 ssh2"

    # Connexions par clé.
    echo "2026-11-04T09:10:00+01:00 $H sshd-session[2601]: Accepted publickey for komlan.djadou from 192.168.122.10 port 42000 ssh2: ED25519 SHA256:AAAAexempleexempleexempleexemple"
    echo "2026-11-04T09:20:00+01:00 $H sshd-session[2602]: Accepted publickey for support from 192.168.122.10 port 42001 ssh2: ED25519 SHA256:BBBBexempleexempleexempleexemple"

    # Après durcissement (clé seule) : échec sans ligne « Failed ».
    echo "2026-11-04T10:00:00+01:00 $H sshd-session[2701]: Connection closed by authenticating user malek.boufaied 198.51.100.77 port 8000 [preauth]"

    # Bruit non compté : balayage de port, déconnexion normale.
    echo "2026-11-04T10:30:00+01:00 $H sshd-session[2801]: Connection closed by 203.0.113.200 port 7000 [preauth]"
    echo "2026-11-04T10:31:00+01:00 $H sshd-session[2602]: Received disconnect from 192.168.122.10 port 42001:11: disconnected by user"
    echo "2026-11-04T10:31:00+01:00 $H sshd-session[2602]: Disconnected from user support 192.168.122.10 port 42001"
} > "$REP/attaque.log"

: > "$REP/vide.log"
mkdir "$REP/un_repertoire"

# ------------------------------------------------------------
# Tests
# ------------------------------------------------------------

echo "== Contrôles statiques"
if "$BASH_BIN" -n "$CIBLE"; then ok "syntaxe Bash (bash -n)"; else ko "syntaxe Bash (bash -n)"; fi
if [[ "$(head -n 1 "$CIBLE")" == "#!/bin/bash" ]]; then ok "shebang #!/bin/bash"; else ko "shebang"; fi
if grep -q $'\r' "$CIBLE"; then ko "fins de ligne LF" "retours chariot CRLF présents"; else ok "fins de ligne LF"; fi
if grep -Eq '(^|[;&|({][[:space:]]*)(eval|source|\.)[[:space:]]' "$CIBLE"; then ko "absence de eval/source"; else ok "absence de eval/source"; fi

echo "== Cas 1 : aucun échec SSH"
lancer -f "$REP/sans_echec.log" -s 5
verifier_code 0 "code 0 sans échec"
verifier_motif "Total : 0 échec" "zéro échec compté"
verifier_motif "Total : 1 connexion\(s\) réussie" "connexion réussie comptée"

echo "== Cas 2 : plusieurs échecs SSH (déduplication par connexion)"
lancer -f "$REP/attaque.log" -s 100
verifier_motif "Total : 15 échec\(s\), depuis 7 adresse\(s\) IP, visant 11 compte\(s\)" "15 échecs, 7 IP, 11 comptes"

echo "== Cas 3 : plusieurs adresses IP"
verifier_motif "      6  203\.0\.113\.45" "203.0.113.45 : 6 échecs (en tête)"
verifier_motif "      4  198\.51\.100\.23" "198.51.100.23 : 4 échecs"
verifier_motif "      1  2001:db8::5" "adresse IPv6 reconnue"
verifier_absence "203\.0\.113\.200" "balayage sans utilisateur non compté"

echo "== Cas 4 : plusieurs comptes ciblés"
verifier_motif "      3  admin +inexistant ou non autorisé" "admin : 3, signalé inexistant"
verifier_motif "      3  support " "support : 3"
verifier_motif "      1  chercheur1 +inexistant ou non autorisé" "chercheur1 hors AllowGroups : 1"
verifier_motif "      1  malek\.boufaied" "échec sans ligne Failed (clé seule) compté"

echo "== Cas 5 : connexions réussies"
verifier_motif "Total : 3 connexion\(s\) réussie\(s\), dont 1 par mot de passe" "3 réussites dont 1 par mot de passe"
verifier_motif "komlan\.djadou +192\.168\.122\.10 +publickey" "réussite par clé détaillée"
verifier_absence "SHA256" "empreinte de clé non affichée"

echo "== Cas 6 : seuil non dépassé"
lancer -f "$REP/attaque.log" -s 7
verifier_code 0 "seuil 7 > maximum (6)"
verifier_motif "OK - aucune adresse IP" "bilan OK"

echo "== Cas 7 : seuil dépassé / atteint"
lancer -f "$REP/attaque.log" -s 5
verifier_code 1 "seuil 5 dépassé"
verifier_motif "ALERTE - 1 adresse\(s\) IP atteignent le seuil : 203\.0\.113\.45" "IP en alerte nommée"
lancer -f "$REP/attaque.log" -s 6
verifier_code 1 "seuil 6 atteint exactement"
lancer -f "$REP/attaque.log" -s 4
verifier_code 1 "seuil 4 : deux IP en alerte"
verifier_motif "ALERTE - 2 adresse\(s\) IP" "deux IP listées"

echo "== Cas 8 : journal vide ou indisponible"
lancer -f "$REP/vide.log" -s 5
verifier_code 0 "journal vide : code 0"
verifier_motif "Aucun événement SSH" "message journal vide"
lancer -f "$REP/inexistant.log"
verifier_code 6 "fichier inexistant : code 6"
lancer -f "$REP/un_repertoire"
verifier_code 6 "répertoire refusé : code 6"

echo "== Cas 9 : dépendance absente (awk retiré du PATH)"
mkdir "$REP/bin"
for outil in sort tail date uname mktemp stat rm cat dirname; do
    chemin="$(command -v "$outil" || true)"
    if [[ -n "$chemin" ]]; then
        ln -s "$chemin" "$REP/bin/$outil" 2>/dev/null || cp "$chemin" "$REP/bin/$outil"
    fi
done
SORTIE="$(PATH="$REP/bin" "$BASH_BIN" "$CIBLE" -f "$REP/attaque.log" 2>&1)" && CODE=0 || CODE=$?
verifier_code 3 "awk absent : code 3"
verifier_motif "absente\(s\) : awk" "dépendance manquante nommée"

echo "== Cas 10 : privilèges et interface"
lancer
verifier_code 4 "sans root et sans -f : code 4"
lancer -s 3
verifier_code 2 "-s sans -f refusé : code 2"
lancer -f "$REP/attaque.log" -s abc
verifier_code 2 "seuil non numérique : code 2"
lancer -f "$REP/attaque.log" -s 0
verifier_code 2 "seuil nul : code 2"
lancer -x
verifier_code 2 "option inconnue : code 2"
lancer -h
verifier_code 0 "aide : code 0"

echo "== Cas 11 : sécurité de l'affichage"
lancer -f "$REP/attaque.log" -s 100
if [[ "$SORTIE" == *"$ESC"* ]]; then
    ko "séquence d'échappement neutralisée"
else
    ok "séquence d'échappement neutralisée"
fi
verifier_motif "\?\?31mevil" "nom hostile affiché assaini"

echo "== Cas 12 : fichier de configuration (chargé sans être exécuté)"
conf_test() {
    # $1 : contenu ; exécute charger_configuration dans un sous-shell.
    printf '%s\n' "$1" > "$REP/test.conf"
    SORTIE="$( {
        # shellcheck source=/dev/null
        source "$CIBLE"
        charger_configuration "$REP/test.conf"
        echo "SEUIL=$SEUIL_ECHECS_IP PERIODE=$PERIODE SOURCE=$SOURCE MAX=$NB_LIGNES_MAX"
    } 2>&1 )" && CODE=0 || CODE=$?
}
conf_test "$(cat "$SCRIPT_DIR/../config/analyse_logs/analyse_logs.conf")"
verifier_code 0 "configuration du dépôt valide"
verifier_motif "SEUIL=5 PERIODE=24h SOURCE=auto MAX=10" "valeurs du dépôt chargées"
conf_test $'# commentaire\n\nSEUIL_ECHECS_IP=12\nPERIODE=7d\r'
verifier_code 0 "commentaires, lignes vides et CRLF tolérés"
verifier_motif "SEUIL=12 PERIODE=7d" "valeurs personnalisées chargées"
conf_test "SEUIL_ECHECS_IP=-3"
verifier_code 5 "seuil négatif : code 5"
conf_test "PERIODE=3w"
verifier_code 5 "période invalide : code 5"
conf_test "COMMANDE=ls"
verifier_code 5 "clé inconnue : code 5"
conf_test "SEUIL_ECHECS_IP=\$(touch $REP/pirate)"
verifier_code 5 "substitution de commande refusée : code 5"
if [[ -e "$REP/pirate" ]]; then ko "aucune commande exécutée depuis la configuration"; else ok "aucune commande exécutée depuis la configuration"; fi

echo
echo "Résultat : $REUSSIS test(s) réussi(s), $ECHOUES échec(s)."
if [[ "$ECHOUES" -gt 0 ]]; then
    exit 1
fi
exit 0
