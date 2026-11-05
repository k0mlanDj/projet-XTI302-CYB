#!/usr/bin/env bash
# Projet XTI302-CYB - Laboratoire BioLab
# Vérification des exigences C1-C4, S1-S5, J1-J4, B1-B4 et D1-D3.
# Aucun changement système : contrôles en lecture seule et temporaires nettoyés.

set -uo pipefail

PASS=0
FAIL=0

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if (( EUID != 0 )); then
    echo "ERREUR : lancer avec sudo : sudo ./verifier.sh" >&2
    exit 2
fi

ok()   { echo "[PASS] $1"; }
ko()   { echo "[FAIL] $1"; }
check() {
    local name="$1"
    shift
    if "$@"; then
        ((PASS+=1))
        ok "$name"
    else
        ((FAIL+=1))
        ko "$name"
    fi
}

# ---------- C1 : Comptes et groupes ----------

test_C1_csv() {
    [[ -f /opt/biolab/comptes.csv ]] &&
    [[ "$(head -n 1 /opt/biolab/comptes.csv)" == "login;nom;groupe_principal;groupes_secondaires" ]]
}

test_C1_comptes() {
    local login nom principal secondaires extra groupe
    while IFS=';' read -r login nom principal secondaires extra; do
        [[ "$login" == "login" ]] && continue
        [[ -n "$login" && -z "${extra:-}" ]] || return 1
        id "$login" >/dev/null 2>&1 || return 1
        getent group "$principal" >/dev/null || return 1
        id -nG "$login" | tr ' ' '\n' | grep -Fxq "$principal" || return 1
        if [[ -n "$secondaires" ]]; then
            IFS=',' read -ra groupes <<< "$secondaires"
            for groupe in "${groupes[@]}"; do
                id -nG "$login" | tr ' ' '\n' | grep -Fxq "$groupe" || return 1
            done
        fi
    done < /opt/biolab/comptes.csv
}

test_C1_groupes() {
    local groupe
    for groupe in admins support technique chercheurs doctorants invite acces_ssh; do
        getent group "$groupe" >/dev/null || return 1
    done
}

# ---------- C2 : Répertoires et ACL ----------

test_C2_repertoires() {
    [[ -d /srv/donnees_brutes && -d /srv/analyses && -d /srv/publications ]]
}

test_C2_acl_brutes() {
    local acl
    acl="$(getfacl -cp /srv/donnees_brutes)" || return 1
    grep -Fxq 'group:technique:rwx' <<< "$acl" &&
    grep -Fxq 'group:chercheurs:r-x' <<< "$acl" &&
    grep -Fxq 'group:doctorants:r-x' <<< "$acl"
}

test_C2_acl_analyses() {
    local acl
    acl="$(getfacl -cp /srv/analyses)" || return 1
    grep -Fxq 'group:chercheurs:rwx' <<< "$acl" &&
    grep -Fxq 'group:doctorants:rwx' <<< "$acl"
}

test_C2_acl_publications() {
    local acl
    acl="$(getfacl -cp /srv/publications)" || return 1
    grep -Fxq 'group:chercheurs:rwx' <<< "$acl" &&
    grep -Fxq 'group:doctorants:r-x' <<< "$acl" &&
    grep -Fxq 'group:invite:r-x' <<< "$acl"
}

test_C2_acl_defaut() {
    getfacl -cp /srv/donnees_brutes | grep -q '^default:group:technique:rwx$' &&
    getfacl -cp /srv/analyses | grep -q '^default:group:chercheurs:rwx$' &&
    getfacl -cp /srv/publications | grep -q '^default:group:invite:r-x$'
}

# ---------- C3 : Sudo ----------

test_C3_admins() {
    local user
    for user in komlan.djadou hugo.boukria malek.boufaied; do
        sudo -l -U "$user" 2>/dev/null | grep -Fq '(ALL : ALL) ALL' || return 1
    done
}

test_C3_support() {
    local rules
    rules="$(sudo -l -U support 2>/dev/null)" || return 1
    grep -Fq '(root) NOPASSWD: /usr/local/sbin/analyse_logs.sh' <<< "$rules" &&
    [[ "$(grep -cE '^[[:space:]]*\(' <<< "$rules")" -eq 1 ]]
}

# ---------- C4 : Protection des comptes ----------

test_C4_root_verrouille() {
    passwd -S root | awk '$2 == "L" {found=1} END {exit !found}'
}

test_C4_homes() {
    local user home mode
    while IFS=';' read -r user _; do
        [[ "$user" == "login" ]] && continue
        home="$(getent passwd "$user" | cut -d: -f6)" || return 1
        [[ -n "$home" && -d "$home" ]] || return 1
        mode="$(stat -c '%a' "$home")"
        [[ "$mode" == "700" ]] || return 1
    done < /opt/biolab/comptes.csv
}

# ---------- S1 à S5 : SSH ----------

SSH_EFFECTIVE="$(sshd -T -C user=komlan.djadou,host=localhost,addr=127.0.0.1 2>/dev/null)"

test_S1_cles_seules() {
    grep -Fxq 'pubkeyauthentication yes' <<< "$SSH_EFFECTIVE" &&
    grep -Fxq 'passwordauthentication no' <<< "$SSH_EFFECTIVE" &&
    grep -Fxq 'authenticationmethods publickey' <<< "$SSH_EFFECTIVE"
}

test_S2_root_interdit() {
    grep -Fxq 'permitrootlogin no' <<< "$SSH_EFFECTIVE"
}

test_S3_groupes_autorises() {
    grep -Fxq 'allowgroups acces_ssh' <<< "$SSH_EFFECTIVE"
}

test_S4_limites() {
    grep -Fxq 'maxauthtries 4' <<< "$SSH_EFFECTIVE" &&
    grep -Fxq 'clientaliveinterval 300' <<< "$SSH_EFFECTIVE" &&
    grep -Fxq 'clientalivecountmax 3' <<< "$SSH_EFFECTIVE"
}

test_S5_configuration_valide() {
    [[ -f /etc/ssh/sshd_config.d/00-biolab-auth.conf ]] &&
    sshd -t
}

# ---------- J1 à J4 : Journaux et sécurité ----------

test_J1_fail2ban() {
    systemctl is-active --quiet fail2ban &&
    fail2ban-client status sshd >/dev/null 2>&1
}

test_J2_nftables() {
    local rules
    rules="$(nft list table inet biolab_filter 2>/dev/null)" || return 1
    grep -Fq 'policy drop' <<< "$rules" &&
    grep -Fq 'tcp dport 22 accept' <<< "$rules" &&
    grep -Fq 'ct state established,related accept' <<< "$rules"
}

test_J3_journald() {
    grep -Fxq 'Storage=persistent' /etc/systemd/journald.conf.d/10-biolab-persistance.conf &&
    [[ -d /var/log/journal ]]
}

test_J4_analyse_logs() {
    [[ -x /usr/local/sbin/analyse_logs.sh ]] &&
    [[ -f /etc/biolab/analyse_logs.conf ]] &&
    bash -n /usr/local/sbin/analyse_logs.sh
}

# ---------- B1 à B4 : Sauvegardes ----------

test_B1_disque() {
    local uuid
    uuid="$(findmnt -rn -M /mnt/biolab-backups -o UUID 2>/dev/null)" || return 1
    [[ "$uuid" == "7a39ce5c-c504-46ee-9bfa-39015532e15e" ]] &&
    [[ "$(findmnt -rn -M /mnt/biolab-backups -o FSTYPE)" == "ext4" ]]
}

test_B2_snapshots() {
    local dir
    dir="$(find /mnt/biolab-backups/snapshots -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)"
    [[ -n "$dir" && -f "$dir/.complete" ]]
}

test_B3_retention() {
    grep -Fxq 'RETENTION_COUNT=7' /etc/biolab-backup.conf &&
    [[ -x /usr/local/sbin/biolab-sauvegarde ]]
}

test_B4_timer() {
    systemctl is-enabled --quiet biolab-sauvegarde.timer &&
    systemctl is-active --quiet biolab-sauvegarde.timer
}

# ---------- D1 à D3 : Durcissement ----------

test_D1_updates() {
    grep -Fxq 'APT::Periodic::Update-Package-Lists "1";' /etc/apt/apt.conf.d/20auto-upgrades &&
    grep -Fxq 'APT::Periodic::Unattended-Upgrade "1";' /etc/apt/apt.conf.d/20auto-upgrades &&
    dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed'
}

test_D2_ports_tcp() {
    local ports
    ports="$(ss -lntH | awk '{n=split($4,a,":"); print a[n]}' | sort -u)"
    [[ -n "$ports" ]] &&
    [[ "$(printf '%s\n' "$ports" | grep -vc '^22$' || true)" -eq 0 ]]
}

test_D3_world_writable() {
    local found
    found="$(find / -xdev \
        \( -path /proc -o -path /sys -o -path /dev -o -path /run \
           -o -path /tmp -o -path /var/tmp \) -prune -o \
        -type f -perm -0002 -print 2>/dev/null)"
    [[ -z "$found" ]]
}

test_D3_suid_inventory() {
    find / -xdev -type f -perm -4000 -print -quit 2>/dev/null | grep -q .
}

# ---------- Exécution ----------

echo "=========================================="
echo " BIO LAB - VERIFICATION DU PROJET XTI302"
echo "=========================================="

check "C1 - En-tête CSV" test_C1_csv
check "C1 - Comptes et groupes principaux/secondaires" test_C1_comptes
check "C1 - Groupes requis" test_C1_groupes

check "C2 - Répertoires BioLab" test_C2_repertoires
check "C2 - ACL donnees_brutes" test_C2_acl_brutes
check "C2 - ACL analyses" test_C2_acl_analyses
check "C2 - ACL publications" test_C2_acl_publications
check "C2 - ACL par défaut" test_C2_acl_defaut

check "C3 - Sudo administrateurs" test_C3_admins
check "C3 - Sudo limité support" test_C3_support

check "C4 - Verrouillage root" test_C4_root_verrouille
check "C4 - Permissions des répertoires personnels" test_C4_homes

check "S1 - Authentification par clé uniquement" test_S1_cles_seules
check "S2 - Connexion root interdite" test_S2_root_interdit
check "S3 - Restriction AllowGroups" test_S3_groupes_autorises
check "S4 - Limites d'authentification et d'inactivité" test_S4_limites
check "S5 - Configuration SSH valide" test_S5_configuration_valide

check "J1 - Fail2ban actif" test_J1_fail2ban
check "J2 - Pare-feu nftables" test_J2_nftables
check "J3 - Journald persistant" test_J3_journald
check "J4 - Script analyse_logs" test_J4_analyse_logs

check "B1 - Disque de sauvegarde" test_B1_disque
check "B2 - Snapshot valide" test_B2_snapshots
check "B3 - Rétention de sept versions" test_B3_retention
check "B4 - Timer systemd" test_B4_timer

check "D1 - Mises à jour automatiques" test_D1_updates
check "D2 - Ports TCP en écoute" test_D2_ports_tcp
check "D3 - Absence de fichiers world-writable" test_D3_world_writable
check "D3 - Inventaire SUID présent" test_D3_suid_inventory

echo
echo "=========================================="
printf 'Résultat : %d PASS / %d FAIL / %d tests\n' \
    "$PASS" "$FAIL" "$((PASS + FAIL))"
echo "=========================================="

if (( FAIL > 0 )); then
    exit 1
fi
exit 0
