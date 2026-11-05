#!/usr/bin/env bash
# Projet XTI302-CYB - Laboratoire BioLab
# Installation et configuration complète du serveur Debian 13.

set -Eeuo pipefail

readonly SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_DIR="/opt/biolab"

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[ATTENTION] %s\n' "$*" >&2; }
fail() { printf '[ERREUR] %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || fail "Exécuter avec sudo : sudo bash installer.sh"

for file in \
    comptes.csv creer_comptes.sh analyse_logs.sh sauvegarde.sh \
    restaurer_sauvegarde.sh \
    config/ssh/sshd_config.d/00-biolab-auth.conf \
    config/sudoers.d/10-biolab-admins \
    config/sudoers.d/20-biolab-support \
    config/fail2ban/jail.local \
    config/fail2ban/filter.d/sshd.local \
    config/journald/10-biolab-persistance.conf \
    config/nftables/nftables.conf \
    config/analyse_logs/analyse_logs.conf \
    config/backup/biolab-sauvegarde.service \
    config/backup/biolab-sauvegarde.timer
do
    [[ -f "$SOURCE_DIR/$file" ]] || fail "Fichier manquant : $file"
done

log "Installation des paquets nécessaires."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    acl attr rsync openssh-server sudo \
    fail2ban python3-systemd nftables \
    unattended-upgrades apt-listchanges \
    cron util-linux e2fsprogs

log "Préparation du répertoire d'installation."
install -d -o root -g root -m 0755 "$INSTALL_DIR"

rsync -a \
    --exclude='.git/' \
    --exclude='logs/' \
    "$SOURCE_DIR/" "$INSTALL_DIR/"

chown -R root:root "$INSTALL_DIR"
chmod 0755 "$INSTALL_DIR"
chmod 0755 "$INSTALL_DIR/creer_comptes.sh"
chmod 0755 "$INSTALL_DIR/analyse_logs.sh"
chmod 0755 "$INSTALL_DIR/sauvegarde.sh"
chmod 0755 "$INSTALL_DIR/restaurer_sauvegarde.sh"
chmod 0640 "$INSTALL_DIR/comptes.csv"
chmod 0644 "$INSTALL_DIR"/config/ssh-keys/*.pub
install -d -o root -g root -m 0700 "$INSTALL_DIR/logs"

log "Installation des comptes, groupes, ACL et clés SSH."
bash "$INSTALL_DIR/creer_comptes.sh"

log "Installation des droits sudo."
install -o root -g root -m 0440 \
    "$INSTALL_DIR/config/sudoers.d/10-biolab-admins" \
    /etc/sudoers.d/10-biolab-admins

install -o root -g root -m 0440 \
    "$INSTALL_DIR/config/sudoers.d/20-biolab-support" \
    /etc/sudoers.d/20-biolab-support

visudo -cf /etc/sudoers >/dev/null || fail "Configuration sudo invalide."

log "Installation du script d'analyse des journaux."
install -d -o root -g root -m 0755 /etc/biolab
install -o root -g root -m 0755 \
    "$INSTALL_DIR/analyse_logs.sh" /usr/local/sbin/analyse_logs.sh
install -o root -g root -m 0640 \
    "$INSTALL_DIR/config/analyse_logs/analyse_logs.conf" \
    /etc/biolab/analyse_logs.conf

log "Installation de la configuration SSH."
install -d -o root -g root -m 0755 /etc/ssh/sshd_config.d
install -o root -g root -m 0644 \
    "$INSTALL_DIR/config/ssh/sshd_config.d/00-biolab-auth.conf" \
    /etc/ssh/sshd_config.d/00-biolab-auth.conf

sshd -t || fail "Configuration SSH invalide. Aucun rechargement effectué."
systemctl reload ssh

log "Installation de Fail2ban."
install -d -o root -g root -m 0755 /etc/fail2ban/filter.d
install -o root -g root -m 0644 \
    "$INSTALL_DIR/config/fail2ban/jail.local" /etc/fail2ban/jail.local
install -o root -g root -m 0644 \
    "$INSTALL_DIR/config/fail2ban/filter.d/sshd.local" \
    /etc/fail2ban/filter.d/sshd.local

log "Installation de journald persistant."
install -d -o root -g root -m 0755 /etc/systemd/journald.conf.d
install -o root -g root -m 0644 \
    "$INSTALL_DIR/config/journald/10-biolab-persistance.conf" \
    /etc/systemd/journald.conf.d/10-biolab-persistance.conf

systemctl restart systemd-journald

log "Installation du pare-feu nftables."
install -o root -g root -m 0644 \
    "$INSTALL_DIR/config/nftables/nftables.conf" /etc/nftables.conf

nft -c -f /etc/nftables.conf || fail "Configuration nftables invalide."
systemctl enable nftables
systemctl restart nftables

log "Activation de Fail2ban."
systemctl enable fail2ban
systemctl restart fail2ban

log "Configuration des mises à jour automatiques."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT

# Les timers APT Debian assurent la planification des mises à jour.

log "Installation des scripts de sauvegarde et restauration."
install -o root -g root -m 0750 \
    "$INSTALL_DIR/sauvegarde.sh" /usr/local/sbin/biolab-sauvegarde
install -o root -g root -m 0750 \
    "$INSTALL_DIR/restaurer_sauvegarde.sh" /usr/local/sbin/biolab-restaurer

install -d -o root -g root -m 0755 /var/log/biolab-backups

install -o root -g root -m 0644 \
    "$INSTALL_DIR/config/backup/biolab-sauvegarde.service" \
    /etc/systemd/system/biolab-sauvegarde.service

install -o root -g root -m 0644 \
    "$INSTALL_DIR/config/backup/biolab-sauvegarde.timer" \
    /etc/systemd/system/biolab-sauvegarde.timer

# Recharger systemd avant toute activation d'unité.
systemctl daemon-reload

# Ne jamais remplacer une configuration existante.
# Ne jamais formater ou partitionner le disque.
if [[ ! -f /etc/biolab-backup.conf ]]; then
    install -o root -g root -m 0640 \
        "$INSTALL_DIR/config/backup/backup.conf.example" \
        /etc/biolab-backup.conf.example
    warn "Configuration de sauvegarde absente : exemple copié uniquement."
    warn "Configurer manuellement /etc/biolab-backup.conf avant activation du timer."
else
    [[ ! -L /etc/biolab-backup.conf ]] || fail "La configuration de sauvegarde ne doit pas être un lien symbolique."

    chown root:root /etc/biolab-backup.conf
    chmod 0640 /etc/biolab-backup.conf

    backup_mount="$(sed -n 's/^BACKUP_MOUNT=//p' /etc/biolab-backup.conf | tail -n 1)"
    backup_uuid="$(sed -n 's/^BACKUP_UUID=//p' /etc/biolab-backup.conf | tail -n 1)"

    if [[ "$backup_mount" != /* || "$backup_mount" == "/" ]]; then
        warn "Point de montage absent ou invalide : timer non activé."
    elif [[ -z "$backup_uuid" || "$backup_uuid" == "REMPLACER_PAR_UUID_REEL" ]]; then
        warn "UUID de sauvegarde absent ou fictif : timer non activé."
    else
        mounted_uuid="$(findmnt -rn -M "$backup_mount" -o UUID 2>/dev/null || true)"

        if [[ -z "$mounted_uuid" || "$mounted_uuid" != "$backup_uuid" ]]; then
            warn "Le disque monté ne correspond pas à l'UUID configuré : timer non activé."
        else
            systemctl enable --now biolab-sauvegarde.timer
            log "Timer de sauvegarde activé après vérification de l'UUID."
        fi
    fi
fi

log "Contrôles finaux."
visudo -cf /etc/sudoers >/dev/null
sshd -t
fail2ban-client ping >/dev/null
systemctl is-active --quiet nftables || fail "nftables inactif."
systemctl is-active --quiet ssh || fail "Service SSH inactif."

log "Installation BioLab terminée."
log "Vérifier les accès SSH avant de fermer la session actuelle."
