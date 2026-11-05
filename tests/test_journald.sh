#!/bin/bash

# ============================================================
# Projet XTI302-CYB - Laboratoire BioLab
# Script : tests/test_journald.sh
# Objectif : vérification de la persistance des journaux (J3)
# ============================================================
#
# Usage :
#   sudo bash tests/test_journald.sh
#       Configuration effective, permissions, écriture d'un événement de
#       test et relecture DIRECTEMENT depuis /var/log/journal (preuve que
#       l'événement est sur disque et non seulement en mémoire).
#
#   sudo bash tests/test_journald.sh --redemarrer-journald
#       Idem, puis redémarrage de systemd-journald et nouvelle relecture.
#
#   sudo bash tests/test_journald.sh --apres-redemarrage
#       À lancer après un redémarrage de la VM : vérifie que le démarrage
#       précédent et ses événements de test sont toujours consultables.
#
# Aucun journal n'est supprimé ; aucune commande --vacuum n'est utilisée.

set -Euo pipefail

readonly DROPIN="/etc/systemd/journald.conf.d/10-biolab-persistance.conf"
readonly REP_JOURNAL="/var/log/journal"
readonly ETIQUETTE="biolab-test-j3"

REUSSIS=0
ECHOUES=0
MODE="${1:-}"

ok() { REUSSIS=$((REUSSIS + 1)); printf '  [OK]    %s\n' "$1"; }
ko() {
    ECHOUES=$((ECHOUES + 1))
    printf '  [ECHEC] %s\n' "$1"
    if [[ -n "${2:-}" ]]; then printf '          %s\n' "$2"; fi
}
info() { printf '  [INFO]  %s\n' "$1"; }

# Dernière valeur effective d'une directive de journald.conf.
valeur_effective() {
    systemd-analyze cat-config systemd/journald.conf 2>/dev/null \
        | sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^[:space:]]*).*/\1/p" \
        | tail -n 1
}

# Vrai si le marqueur est lisible dans les fichiers de /var/log/journal.
marqueur_sur_disque() {
    local contenu
    contenu="$(journalctl -D "$REP_JOURNAL" -q --no-pager -o cat -t "$ETIQUETTE" 2>/dev/null)" || return 1
    [[ "$contenu" == *"$1"* ]]
}

case "$MODE" in
    ""|--redemarrer-journald|--apres-redemarrage) ;;
    *) echo "Usage : sudo bash $0 [--redemarrer-journald | --apres-redemarrage]" >&2; exit 2 ;;
esac

if [[ "$EUID" -ne 0 ]]; then
    echo "ERREUR : exécuter avec sudo." >&2
    exit 2
fi

echo "== 1. Configuration journald"
if [[ -f "$DROPIN" && "$(stat -c '%U:%G %a' "$DROPIN")" == "root:root 644" ]]; then
    ok "$DROPIN présent (root:root 644)"
else
    ko "$DROPIN présent (root:root 644)" "$(stat -c '%U:%G %a' "$DROPIN" 2>&1)"
fi
storage="$(valeur_effective Storage)"
[[ "$storage" == "persistent" ]] && ok "Storage effectif = persistent" || ko "Storage effectif" "obtenu « ${storage:-défaut (auto)} »"
for directive in SystemMaxUse SystemKeepFree SystemMaxFileSize MaxRetentionSec RuntimeMaxUse; do
    info "$directive effectif = $(valeur_effective "$directive")"
done
[[ "$(systemctl is-active systemd-journald)" == "active" ]] && ok "systemd-journald actif" || ko "systemd-journald actif"

echo "== 2. Répertoire persistant et permissions"
machine_id="$(cat /etc/machine-id)"
if [[ -d "$REP_JOURNAL" ]]; then
    droits="$(stat -c '%U:%G %a' "$REP_JOURNAL")"
    [[ "$droits" == "root:systemd-journal 2755" ]] && ok "$REP_JOURNAL : $droits" || ko "$REP_JOURNAL root:systemd-journal 2755" "obtenu $droits"
else
    ko "$REP_JOURNAL existe"
fi
if [[ -d "$REP_JOURNAL/$machine_id" ]]; then
    ok "$REP_JOURNAL/$machine_id existe ($(stat -c '%U:%G %a' "$REP_JOURNAL/$machine_id"))"
else
    ko "$REP_JOURNAL/$machine_id existe"
fi
if [[ -f "$REP_JOURNAL/$machine_id/system.journal" ]]; then
    droits="$(stat -c '%U:%G %a' "$REP_JOURNAL/$machine_id/system.journal")"
    [[ "$droits" == root:systemd-journal\ 6[04]0 ]] && ok "system.journal : $droits" || ko "system.journal root:systemd-journal 640" "obtenu $droits"
else
    ko "journal système actif dans $REP_JOURNAL/$machine_id"
fi
if command -v getfacl >/dev/null 2>&1; then
    info "ACL $REP_JOURNAL : $(getfacl -cp "$REP_JOURNAL" 2>/dev/null | tr '\n' ' ')"
fi
info "occupation : $(journalctl --disk-usage 2>&1)"
info "démarrages conservés : $(journalctl --list-boots --no-pager 2>/dev/null | awk 'END { print NR }')"

if [[ "$MODE" == "--apres-redemarrage" ]]; then
    echo "== 3. Après redémarrage de la VM"
    nb_boots="$(journalctl --list-boots --no-pager 2>/dev/null | awk 'END { print NR }')"
    if [[ "$nb_boots" -ge 2 ]]; then ok "$nb_boots démarrages conservés"; else ko "au moins 2 démarrages conservés" "obtenu $nb_boots"; fi
    precedents="$(journalctl -b -1 -q --no-pager -o short-iso -t "$ETIQUETTE" 2>/dev/null || true)"
    if [[ -n "$precedents" ]]; then
        ok "événements de test du démarrage précédent toujours présents :"
        printf '%s\n' "$precedents" | sed 's/^/          /'
    else
        ko "événements de test du démarrage précédent" "lancer d'abord le test sans option, puis redémarrer la VM"
    fi
else
    echo "== 3. Événement de test"
    marqueur="BIOLAB-J3-$(date '+%Y%m%dT%H%M%S')-$$"
    logger -t "$ETIQUETTE" -- "$marqueur"
    journalctl --sync
    trouve=0
    for _ in 1 2 3 4 5; do
        if marqueur_sur_disque "$marqueur"; then trouve=1; break; fi
        sleep 1
    done
    [[ "$trouve" -eq 1 ]] && ok "événement $marqueur relu depuis $REP_JOURNAL (sur disque)" \
        || ko "événement relu depuis $REP_JOURNAL" "journal probablement volatile (/run/log/journal)"

    if [[ "$MODE" == "--redemarrer-journald" ]]; then
        echo "== 4. Redémarrage de systemd-journald"
        systemctl restart systemd-journald
        sleep 2
        [[ "$(systemctl is-active systemd-journald)" == "active" ]] && ok "systemd-journald actif après redémarrage" || ko "systemd-journald actif après redémarrage"
        marqueur_sur_disque "$marqueur" && ok "événement $marqueur toujours disponible" || ko "événement toujours disponible après redémarrage du service"
    fi
    info "étape suivante : redémarrer la VM puis lancer « sudo bash $0 --apres-redemarrage »"
fi

echo
echo "Résultat : $REUSSIS test(s) réussi(s), $ECHOUES échec(s)."
[[ "$ECHOUES" -eq 0 ]]
