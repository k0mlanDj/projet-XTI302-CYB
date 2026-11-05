#!/bin/bash

# ============================================================
# Projet XTI302-CYB - Laboratoire BioLab
# Script : tests/test_fail2ban.sh
# Objectif : vérification de la protection SSH par fail2ban (J1)
# ============================================================
#
# Usage :
#   sudo bash tests/test_fail2ban.sh
#       Contrôles de l'installation, du service, de la jail, des paramètres
#       effectifs, de la détection (fail2ban-regex), puis bannissement et
#       débannissement manuels d'une adresse de documentation (192.0.2.66,
#       RFC 5737), qui ne peut correspondre à aucun poste réel.
#
#   sudo bash tests/test_fail2ban.sh --bannissement-reel
#       En plus : vraies tentatives SSH depuis un espace de noms réseau
#       isolé (10.203.0.2), bannissement automatique, contrôle du blocage,
#       débannissement. L'espace de noms et la paire veth sont supprimés à
#       la fin. L'accès d'administration (192.168.122.1) n'est jamais
#       utilisé ni concerné. Garder une session SSH ouverte pendant le test.
#
# Ne modifie ni sshd, ni nftables.service, ni les comptes.

set -Euo pipefail

readonly JAIL="sshd"
readonly IP_ADMIN="192.168.122.1"
readonly IP_TEST="192.0.2.66"
readonly NS="biolab-f2b-test"
readonly VETH_HOTE="vf2b-hote"
readonly VETH_NS="vf2b-ns"
readonly IP_HOTE="10.203.0.1"
readonly IP_NS="10.203.0.2"
readonly ATTENDU_MAXRETRY="5"
readonly ATTENDU_FINDTIME="600"
readonly ATTENDU_BANTIME="3600"

REUSSIS=0
ECHOUES=0
REP=""
NS_CREE=0
MODE_REEL=0

ok() { REUSSIS=$((REUSSIS + 1)); printf '  [OK]    %s\n' "$1"; }
ko() {
    ECHOUES=$((ECHOUES + 1))
    printf '  [ECHEC] %s\n' "$1"
    if [[ -n "${2:-}" ]]; then printf '          %s\n' "$2"; fi
}
info() { printf '  [INFO]  %s\n' "$1"; }

nettoyer() {
    if [[ "$NS_CREE" -eq 1 ]]; then
        fail2ban-client set "$JAIL" unbanip "$IP_NS" >/dev/null 2>&1 || true
        ip netns del "$NS" 2>/dev/null || true
        ip link del "$VETH_HOTE" 2>/dev/null || true
    fi
    fail2ban-client set "$JAIL" unbanip "$IP_TEST" >/dev/null 2>&1 || true
    if [[ -n "$REP" && -d "$REP" ]]; then rm -rf -- "$REP"; fi
}

# Vrai si l'adresse figure dans la liste des bannis de la jail.
est_bannie() {
    local etat liste
    etat="$(fail2ban-client status "$JAIL" 2>/dev/null)" || return 1
    liste="$(printf '%s\n' "$etat" | sed -n 's/.*Banned IP list:[[:space:]]*//p')"
    [[ " $liste " == *" $1 "* ]]
}

# Vrai si la jail figure dans la liste des jails chargées.
jail_chargee() {
    local etat liste
    etat="$(fail2ban-client status 2>/dev/null)" || return 1
    liste="$(printf '%s\n' "$etat" | sed -n 's/.*Jail list:[[:space:]]*//p')"
    liste="${liste//,/ }"
    [[ " $liste " == *" $1 "* ]]
}

preparer_espace_de_noms() {
    NS_CREE=1
    ip netns add "$NS" \
        && ip link add "$VETH_HOTE" type veth peer name "$VETH_NS" \
        && ip link set "$VETH_NS" netns "$NS" \
        && ip addr add "$IP_HOTE/30" dev "$VETH_HOTE" \
        && ip link set "$VETH_HOTE" up \
        && ip netns exec "$NS" ip addr add "$IP_NS/30" dev "$VETH_NS" \
        && ip netns exec "$NS" ip link set "$VETH_NS" up \
        && ip netns exec "$NS" ip link set lo up
}

# Vrai si l'adresse figure dans la table nftables de fail2ban.
dans_nftables() {
    local table
    table="$(nft list table inet f2b-table 2>/dev/null)" || return 1
    [[ "$table" == *"$1"* ]]
}

port_ssh_joignable_depuis_ns() {
    ip netns exec "$NS" timeout 5 bash -c "exec 3<>/dev/tcp/$IP_HOTE/22" 2>/dev/null
}

verifier_valeur() {
    local option="$1" attendu="$2" obtenu
    obtenu="$(fail2ban-client get "$JAIL" "$option" 2>&1)" || true
    if [[ "$obtenu" == "$attendu" ]]; then
        ok "$option effectif = $attendu"
    else
        ko "$option effectif" "obtenu « $obtenu », attendu « $attendu »"
    fi
}

# ------------------------------------------------------------

case "${1:-}" in
    "") ;;
    --bannissement-reel) MODE_REEL=1 ;;
    *) echo "Usage : sudo bash $0 [--bannissement-reel]" >&2; exit 2 ;;
esac

if [[ "$EUID" -ne 0 ]]; then
    echo "ERREUR : exécuter avec sudo." >&2
    exit 2
fi

trap nettoyer EXIT
REP="$(mktemp -d /tmp/test_fail2ban.XXXXXXXX)"

echo "== 1. Installation"
for paquet in fail2ban python3-systemd nftables; do
    if [[ "$(dpkg-query -W -f='${Status}' "$paquet" 2>/dev/null)" == "install ok installed" ]]; then
        ok "paquet $paquet installé ($(dpkg-query -W -f='${Version}' "$paquet"))"
    else
        ko "paquet $paquet installé"
    fi
done
for outil in fail2ban-client fail2ban-regex nft; do
    if command -v "$outil" >/dev/null 2>&1; then ok "commande $outil présente"; else ko "commande $outil présente"; fi
done
if ! command -v fail2ban-client >/dev/null 2>&1; then
    echo "fail2ban absent : arrêt des tests."
    exit 1
fi

echo "== 2. Fichiers de configuration"
for f in /etc/fail2ban/jail.local /etc/fail2ban/filter.d/sshd.local; do
    if [[ -f "$f" && "$(stat -c '%U:%G %a' "$f")" == "root:root 644" ]]; then
        ok "$f présent (root:root 644)"
    else
        ko "$f présent (root:root 644)" "$(stat -c '%U:%G %a' "$f" 2>&1)"
    fi
done
if fail2ban-client -t >/dev/null 2>&1; then ok "fail2ban-client -t : configuration valide"; else ko "fail2ban-client -t" "$(fail2ban-client -t 2>&1 | tail -n 3)"; fi

echo "== 3. Service"
[[ "$(systemctl is-active fail2ban)" == "active" ]] && ok "service fail2ban actif" || ko "service fail2ban actif"
[[ "$(systemctl is-enabled fail2ban 2>/dev/null)" == "enabled" ]] && ok "service fail2ban activé au démarrage" || ko "service fail2ban activé au démarrage"
[[ "$(fail2ban-client ping 2>&1)" == *pong* ]] && ok "fail2ban-client ping : pong" || ko "fail2ban-client ping"
info "nftables.service : $(systemctl is-active nftables 2>/dev/null || true) (non requis par l'action fail2ban)"
info "fail2ban.service PartOf = $(systemctl show fail2ban -p PartOf --value 2>/dev/null || true)"

echo "== 4. Jail SSH chargée et paramètres effectifs"
if jail_chargee "$JAIL"; then ok "jail $JAIL chargée"; else ko "jail $JAIL chargée" "$(fail2ban-client status 2>&1)"; fi
verifier_valeur maxretry "$ATTENDU_MAXRETRY"
verifier_valeur findtime "$ATTENDU_FINDTIME"
verifier_valeur bantime "$ATTENDU_BANTIME"
valeur="$(fail2ban-client get "$JAIL" ignoreip 2>&1)" || true
[[ "$valeur" == *"$IP_ADMIN"* ]] && ok "ignoreip contient $IP_ADMIN" || ko "ignoreip contient $IP_ADMIN" "$valeur"
valeur="$(fail2ban-client get "$JAIL" journalmatch 2>&1)" || true
[[ "$valeur" == *"_SYSTEMD_UNIT=ssh.service"* ]] && ok "journalmatch = _SYSTEMD_UNIT=ssh.service" || ko "journalmatch" "$valeur"
valeur="$(fail2ban-client get "$JAIL" actions 2>&1)" || true
[[ "$valeur" == *nftables* ]] && ok "action nftables active ($valeur)" || ko "action nftables" "$valeur"
info "bantime.increment = $(fail2ban-client get "$JAIL" bantime.increment 2>&1 || true)"
if est_bannie "$IP_ADMIN"; then ko "$IP_ADMIN non bannie"; else ok "$IP_ADMIN non bannie"; fi

echo "== 5. Détection des échecs (fail2ban-regex, format Debian 13)"
horo="$(LC_ALL=C date '+%b %d %H:%M:%S')"
cat > "$REP/echantillon.log" <<EOF
$horo Debian13-BioLab sshd-session[1128]: Invalid user admin from 203.0.113.45 port 41022
$horo Debian13-BioLab sshd-session[1128]: Failed password for invalid user admin from 203.0.113.45 port 41022 ssh2
$horo Debian13-BioLab sshd-session[1129]: Failed password for support from 198.51.100.23 port 40001 ssh2
$horo Debian13-BioLab sshd-session[1130]: User chercheur1 from 198.51.100.23 not allowed because none of user's groups are listed in AllowGroups
$horo Debian13-BioLab sshd-session[1131]: Accepted publickey for hugo.boukria from 192.168.122.1 port 41210 ssh2: ED25519 SHA256:exemple
EOF
resultat="$(fail2ban-regex "$REP/echantillon.log" "$JAIL" 2>&1)" || true
correspondances="$(printf '%s\n' "$resultat" | sed -nE 's/^Lines: [0-9]+ lines, [0-9]+ ignored, ([0-9]+) matched.*/\1/p')"
if [[ "$correspondances" == "4" ]]; then
    ok "4 échecs reconnus sur 4 (préfixe sshd-session accepté), connexion réussie ignorée"
else
    ko "détection des échecs sshd-session" "lignes reconnues : ${correspondances:-?} (attendu 4)"
fi
resultat="$(timeout 60 fail2ban-regex systemd-journal "$JAIL" 2>&1)" || true
info "journal réel : $(printf '%s\n' "$resultat" | grep -E '^Lines:' || echo 'résultat indisponible')"

echo "== 6. Bannissement / débannissement contrôlés ($IP_TEST, RFC 5737)"
fail2ban-client set "$JAIL" banip "$IP_TEST" >/dev/null 2>&1 || true
sleep 1
est_bannie "$IP_TEST" && ok "$IP_TEST bannie dans la jail" || ko "$IP_TEST bannie dans la jail"
dans_nftables "$IP_TEST" && ok "$IP_TEST présente dans nft (table inet f2b-table)" || ko "$IP_TEST présente dans nftables"
fail2ban-client set "$JAIL" unbanip "$IP_TEST" >/dev/null 2>&1 || true
sleep 1
est_bannie "$IP_TEST" && ko "$IP_TEST débannie (jail)" || ok "$IP_TEST débannie (jail)"
dans_nftables "$IP_TEST" && ko "$IP_TEST retirée de nftables" || ok "$IP_TEST retirée de nftables"

if [[ "$MODE_REEL" -eq 1 ]]; then
    echo "== 7. Bannissement réel depuis un espace de noms réseau isolé ($IP_NS)"
    for outil in ip ssh timeout; do
        command -v "$outil" >/dev/null 2>&1 || { ko "commande $outil présente"; exit 1; }
    done
    if [[ " $(ip netns list 2>/dev/null | tr '\n' ' ') " == *" $NS "* ]]; then
        ko "espace de noms $NS inexistant avant le test" "supprimer l'ancien : ip netns del $NS"
        exit 1
    fi
    if ! preparer_espace_de_noms; then
        ko "création de l'espace de noms réseau de test"
        exit 1
    fi
    ok "espace de noms $NS créé ($IP_NS -> $IP_HOTE)"

    if ! port_ssh_joignable_depuis_ns; then
        ko "port 22 joignable depuis $IP_NS avant le test" \
            "un pare-feu (J2) bloque peut-être l'interface $VETH_HOTE : test non concluant"
    else
        ok "port 22 joignable depuis $IP_NS avant le test"
        for i in $(seq 1 "$ATTENDU_MAXRETRY"); do
            ip netns exec "$NS" timeout 10 ssh -n -F /dev/null \
                -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=5 -o PubkeyAuthentication=no -o GSSAPIAuthentication=no \
                -o LogLevel=QUIET "f2b-test-inexistant@$IP_HOTE" true >/dev/null 2>&1 || true
            info "tentative $i/$ATTENDU_MAXRETRY envoyée (compte inexistant)"
            if est_bannie "$IP_NS"; then break; fi
        done
        for _ in $(seq 1 30); do
            est_bannie "$IP_NS" && break
            sleep 1
        done
        est_bannie "$IP_NS" && ok "$IP_NS bannie automatiquement" || ko "$IP_NS bannie automatiquement"
        dans_nftables "$IP_NS" && ok "$IP_NS présente dans nftables" || ko "$IP_NS présente dans nftables"
        port_ssh_joignable_depuis_ns && ko "port 22 bloqué pour $IP_NS" || ok "port 22 bloqué pour $IP_NS"
        info "procédure de débannissement : fail2ban-client set $JAIL unbanip $IP_NS"
        fail2ban-client set "$JAIL" unbanip "$IP_NS" >/dev/null 2>&1 || true
        sleep 1
        est_bannie "$IP_NS" && ko "$IP_NS débannie" || ok "$IP_NS débannie"
        port_ssh_joignable_depuis_ns && ok "port 22 de nouveau joignable" || ko "port 22 de nouveau joignable"
    fi
fi

echo
echo "Résultat : $REUSSIS test(s) réussi(s), $ECHOUES échec(s)."
[[ "$ECHOUES" -eq 0 ]]
