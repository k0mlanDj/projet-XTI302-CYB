#!/usr/bin/env bash
# BioLab B4 : extraction securisee vers /var/tmp/biolab-restauration,
# jamais vers /srv ou /etc directement.
# Installation : /usr/local/sbin/biolab-restaurer (root:root 0750).
set -Eeuo pipefail
umask 027

CONF_FILE=/etc/biolab-backup.conf
RESTORE_ROOT=/var/tmp/biolab-restauration

fail() { printf 'ERREUR : %s\n' "$*" >&2; exit 1; }
usage() {
    echo "Usage : $0 VERSION {srv|etc}/chemin/relatif"
    echo "Exemple : $0 20261104_163000_123456789 srv/analyses/test.txt"
    exit 2
}

[[ $# -eq 2 ]] || usage
(( EUID == 0 )) || fail 'Execution root requise.'
for cmd in rsync findmnt blkid readlink stat install getent; do
    command -v "$cmd" >/dev/null || fail "Outil absent : $cmd"
done
getent group admins >/dev/null || fail 'Groupe admins absent.'
[[ -f "$CONF_FILE" && ! -L "$CONF_FILE" && "$(stat -c %u "$CONF_FILE")" == 0 ]] || fail 'Configuration root absente.'
mode="$(stat -c %a "$CONF_FILE")"
(( (8#$mode & 022) == 0 )) || fail 'Configuration modifiable par groupe/autres.'
# shellcheck source=/dev/null
source "$CONF_FILE"

version="$1"
relative="$2"
[[ "$version" =~ ^[0-9]{8}_[0-9]{6}_[0-9]{9}$ ]] || fail 'Nom de version incorrect.'
[[ "$relative" == 'srv/'* || "$relative" == 'etc/'* ]] || fail 'Chemin exige : srv/... ou etc/...'
[[ "$relative" != */ && "$relative" != *//* ]] || fail 'Chemin non canonique.'
IFS='/' read -r -a components <<< "$relative"
for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != '.' && "$component" != '..' ]] || fail 'Composant de chemin interdit.'
done
[[ "$BACKUP_MOUNT" == /* && "$BACKUP_MOUNT" != / ]] || fail 'Chemin montage invalide.'
[[ "$BACKUP_DEVICE" == /dev/* && -b "$BACKUP_DEVICE" ]] || fail 'Disque absent.'
[[ "$BACKUP_UUID" =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ && "$BACKUP_FSTYPE" == ext4 ]] || fail 'Configuration de disque invalide.'
[[ -d "$BACKUP_MOUNT" && ! -L "$BACKUP_MOUNT" ]] || fail 'Montage absent ou chemin symbolique.'
actual_source="$(findmnt -rn -M "$BACKUP_MOUNT" -o SOURCE 2>/dev/null)" || fail 'Disque non monte.'
actual_uuid="$(findmnt -rn -M "$BACKUP_MOUNT" -o UUID 2>/dev/null)" || fail 'UUID non disponible.'
actual_fstype="$(findmnt -rn -M "$BACKUP_MOUNT" -o FSTYPE 2>/dev/null)" || fail 'Type FS non disponible.'
[[ -b "$actual_source" && "$actual_uuid" == "$BACKUP_UUID" && "$actual_fstype" == "$BACKUP_FSTYPE" \
  && "$(readlink -f "$actual_source")" == "$(readlink -f "$BACKUP_DEVICE")" \
  && "$(blkid -s UUID -o value "$actual_source")" == "$BACKUP_UUID" ]] || fail 'Mauvais disque/montage.'

snapshot="$BACKUP_MOUNT/snapshots/$version"
[[ -d "$snapshot" && ! -L "$snapshot" && -f "$snapshot/.complete" ]] || fail 'Version absente ou non valide.'

# Aucune partie intermediaire du chemin source ne peut etre un lien symbolique.
parent="$snapshot"
for ((i=0; i<${#components[@]}-1; i++)); do
    parent="$parent/${components[$i]}"
    [[ -d "$parent" && ! -L "$parent" ]] || fail "Repertoire source invalide : $parent"
done
source_path="$snapshot/$relative"
[[ -e "$source_path" || -L "$source_path" ]] || fail 'Fichier ou repertoire introuvable.'

[[ ! -L "$RESTORE_ROOT" ]] || fail 'Chemin de restauration symbolique.'
install -d -o root -g admins -m 0750 "$RESTORE_ROOT"
version_root="$RESTORE_ROOT/$version"
[[ ! -L "$version_root" ]] || fail 'Version de restauration symbolique.'
install -d -o root -g admins -m 0750 "$version_root"
destination="$version_root/$relative"
[[ ! -e "$destination" && ! -L "$destination" ]] || fail "Refus d ecraser une destination existante : $destination"
# Refuser un lien symbolique dans tout parent de destination deja existant.
dest_parent="$version_root"
for ((i=0; i<${#components[@]}-1; i++)); do
    [[ ! -L "$dest_parent/${components[$i]}" ]] || fail 'Lien symbolique dans la destination.'
    dest_parent="$dest_parent/${components[$i]}"
done
install -d -o root -g admins -m 0750 "$(dirname "$destination")"

printf 'Version source : %s\nElement source : %s\nDestination test : %s\n' "$version" "$source_path" "$destination"
if [[ -d "$source_path" && ! -L "$source_path" ]]; then
    # Le repertoire destination est cree a partir du repertoire source,
    # et ses droits + ACL seront reproduits par rsync -aAXH.
    rsync -n -aAXH --numeric-ids --itemize-changes -- "$source_path/" "$destination/"
    rsync -aAXH --numeric-ids -- "$source_path/" "$destination/"
else
    rsync -n -aAXH --numeric-ids --itemize-changes -- "$source_path" "$destination"
    rsync -aAXH --numeric-ids -- "$source_path" "$destination"
fi
printf 'RESTAURATION TEST REUSSIE : %s\n' "$destination"
printf 'IMPORTANT : comparer les contenus, proprietaires, droits et ACL avant toute remise en production.\n'
