#!/usr/bin/env bash
# BioLab - B1/B2/B3 : copies datees de /srv et /etc sur un disque dedie.
# Installation : /usr/local/sbin/biolab-sauvegarde (root:root 0750).
# NE PARTITIONNE PAS, NE FORMATE PAS ET NE MONTE PAS DE DISQUE.
set -Eeuo pipefail
umask 027

readonly CONF_FILE='/etc/biolab-backup.conf'
readonly LOG_DIR='/var/log/biolab-backups'
readonly LOG_FILE="$LOG_DIR/sauvegarde.log"
readonly LOCK_FILE='/run/lock/biolab-sauvegarde.lock'
readonly GROUP='admins'

BACKUP_MOUNT=''
BACKUP_DEVICE=''
BACKUP_UUID=''
BACKUP_FSTYPE=''
RETENTION_COUNT=''
MIN_FREE_MIB=''
STAGING_DIR=''
SNAPSHOTS_DIR=''
VERSION=''
COMPLETED=0

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"; }
fail() { log "ERREUR : $*" >&2; exit 1; }

require_root() {
    (( EUID == 0 )) || fail 'Execution root requise (timer systemd ou sudo autorise).'
}

require_tools() {
    local tool
    for tool in rsync findmnt blkid readlink stat getent install chmod chown flock \
                df du awk date mkdir mv rm sync touch grep; do
        command -v "$tool" >/dev/null 2>&1 || fail "Outil manquant : $tool"
    done
}

init_logging() {
    getent group "$GROUP" >/dev/null || fail "Groupe absent : $GROUP"
    [[ ! -L "$LOG_DIR" && ! -L "$LOG_FILE" ]] || fail 'Lien symbolique dans le chemin de journalisation.'
    install -d -o root -g "$GROUP" -m 0750 "$LOG_DIR"
    touch -- "$LOG_FILE"
    chown root:"$GROUP" "$LOG_FILE"
    chmod 0640 "$LOG_FILE"
    exec >>"$LOG_FILE" 2>&1
}

load_config() {
    [[ -f "$CONF_FILE" && ! -L "$CONF_FILE" ]] || fail "Configuration absente : $CONF_FILE"
    [[ "$(stat -c '%u' -- "$CONF_FILE")" == '0' ]] || fail 'Configuration non possedee par root.'
    local mode
    mode="$(stat -c '%a' -- "$CONF_FILE")"
    (( (8#$mode & 022) == 0 )) || fail 'Configuration modifiable par groupe/autres.'
    # Le fichier est installe exclusivement par root, hors du depot modifiable.
    # shellcheck source=/dev/null
    source "$CONF_FILE"

    : "${BACKUP_MOUNT:?BACKUP_MOUNT absent}"
    : "${BACKUP_DEVICE:?BACKUP_DEVICE absent}"
    : "${BACKUP_UUID:?BACKUP_UUID absent}"
    : "${BACKUP_FSTYPE:?BACKUP_FSTYPE absent}"
    : "${RETENTION_COUNT:?RETENTION_COUNT absent}"
    : "${MIN_FREE_MIB:?MIN_FREE_MIB absent}"

    [[ "$BACKUP_MOUNT" == /* && "$BACKUP_MOUNT" != '/' && "$BACKUP_MOUNT" != '/srv' \
       && "$BACKUP_MOUNT" != '/etc' && "$BACKUP_MOUNT" != '/var' ]] || fail 'Point de montage invalide.'
    [[ ! -L "$BACKUP_MOUNT" && -d "$BACKUP_MOUNT" ]] || fail 'Point de montage absent ou lien symbolique.'
    [[ "$(readlink -f -- "$BACKUP_MOUNT")" == "$BACKUP_MOUNT" ]] || fail 'Chemin de montage non canonique.'
    [[ "$BACKUP_DEVICE" == /dev/* && -b "$BACKUP_DEVICE" ]] || fail 'Peripherique configure absent/invalide.'
    [[ "$BACKUP_UUID" =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]] || fail 'UUID incorrect ou non renseigne.'
    [[ "$BACKUP_FSTYPE" == 'ext4' ]] || fail 'Seul ext4 est valide dans cette configuration BioLab.'
    [[ "$RETENTION_COUNT" =~ ^[0-9]+$ ]] || fail 'Retention non numerique.'
    (( RETENTION_COUNT >= 7 && RETENTION_COUNT <= 1000 )) || fail 'Retention >= 7 et <= 1000 requise.'
    [[ "$MIN_FREE_MIB" =~ ^[0-9]+$ ]] || fail 'Reserve libre non numerique.'
    (( MIN_FREE_MIB >= 64 && MIN_FREE_MIB <= 8192 )) || fail 'Reserve libre hors limites.'
    SNAPSHOTS_DIR="$BACKUP_MOUNT/snapshots"
}

verify_mount() {
    local source fstype uuid actual_device expected_device root_uuid srv_uuid
    # -M exige un montage EXACTEMENT sur BACKUP_MOUNT (et non son parent /).
    source="$(findmnt -rn -M "$BACKUP_MOUNT" -o SOURCE 2>/dev/null)" || fail 'Disque de sauvegarde non monte.'
    fstype="$(findmnt -rn -M "$BACKUP_MOUNT" -o FSTYPE)" || fail 'FSTYPE introuvable.'
    uuid="$(findmnt -rn -M "$BACKUP_MOUNT" -o UUID)" || fail 'UUID de montage introuvable.'
    [[ "$fstype" == "$BACKUP_FSTYPE" && "$uuid" == "$BACKUP_UUID" ]] || fail 'Type/UUID du disque incompatibles.'
    [[ -b "$source" ]] || fail 'La source de montage n est pas un peripherique bloc.'
    actual_device="$(readlink -f -- "$source")"
    expected_device="$(readlink -f -- "$BACKUP_DEVICE")"
    [[ "$actual_device" == "$expected_device" ]] || fail 'Le mauvais peripherique est monte.'
    [[ "$(blkid -s UUID -o value -- "$actual_device")" == "$BACKUP_UUID" ]] || fail 'UUID blkid different.'
    root_uuid="$(findmnt -rn -M '/' -o UUID 2>/dev/null || true)"
    srv_uuid="$(findmnt -rn -M '/srv' -o UUID 2>/dev/null || true)"
    [[ "$BACKUP_UUID" != "$root_uuid" && "$BACKUP_UUID" != "$srv_uuid" ]] || fail 'Disque systeme ou /srv utilise comme sauvegarde.'
    [[ -w "$BACKUP_MOUNT" ]] || fail 'Disque non inscriptible.'
}

check_capacity() {
    local source_bytes available_bytes reserve_bytes needed_bytes
    # Estimation volontairement prudente : taille allouee complete de /srv + /etc,
    # meme si --link-dest ne recopiera en pratique que les fichiers modifies.
    source_bytes="$(du -s -B1 -- /srv /etc | awk '{s += $1} END {printf "%.0f", s}')"
    available_bytes="$(df -PB1 -- "$BACKUP_MOUNT" | awk 'END {print $4}')"
    [[ "$source_bytes" =~ ^[0-9]+$ && "$available_bytes" =~ ^[0-9]+$ ]] || fail 'Controle de capacite impossible.'
    reserve_bytes=$((MIN_FREE_MIB * 1024 * 1024))
    needed_bytes=$((source_bytes + reserve_bytes))
    log "Controle espace : sources=$source_bytes octets, libres=$available_bytes octets, minimum=$needed_bytes octets."
    (( available_bytes >= needed_bytes )) || fail 'Espace insuffisant : sauvegarde annulee avant ecriture.'
}

prepare_directories() {
    [[ ! -L "$SNAPSHOTS_DIR" && ! -L "$BACKUP_MOUNT/.incomplete" ]] || fail 'Lien symbolique suspect dans le stockage.'
    install -d -o root -g "$GROUP" -m 0750 "$SNAPSHOTS_DIR"
    install -d -o root -g root -m 0700 "$BACKUP_MOUNT/.incomplete"
    [[ "$(stat -c '%u' "$SNAPSHOTS_DIR")" == '0' ]] || fail 'Proprietaire de snapshots incorrect.'
}

list_valid_snapshots() {
    local candidate name
    shopt -s nullglob
    for candidate in "$SNAPSHOTS_DIR"/*; do
        name="${candidate##*/}"
        [[ "$name" =~ ^[0-9]{8}_[0-9]{6}_[0-9]{9}$ ]] || continue
        [[ ! -L "$candidate" && -d "$candidate" && -f "$candidate/.complete" ]] || continue
        printf '%s\n' "$candidate"
    done
}

clean_failed_stage() {
    if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" && ! -L "$STAGING_DIR" ]]; then
        # Si le disque a disparu, ne jamais supprimer quoi que ce soit
        # dans un simple repertoire sous le disque systeme.
        if findmnt -rn -M "$BACKUP_MOUNT" -o UUID 2>/dev/null | grep -Fxq "$BACKUP_UUID"; then
            rm -rf --one-file-system -- "$STAGING_DIR" || log 'AVERTISSEMENT : nettoyage de .incomplete impossible.'
        else
            log 'AVERTISSEMENT : montage absent ; aucun nettoyage sur le disque systeme.'
        fi
    fi
}

on_exit() {
    local status="$1"
    trap - EXIT
    if (( status != 0 )); then
        if (( COMPLETED == 1 )); then
            log "SAUVEGARDE PUBLIEE MAIS ECHEC APRES PUBLICATION (code=$status, version=$VERSION ; verifier la retention)."
        else
            log "ECHEC de la sauvegarde (code=$status, version=${VERSION:-aucune})."
        fi
        clean_failed_stage
    elif (( COMPLETED == 1 )); then
        log "SUCCES de la sauvegarde (version=$VERSION)."
    fi
}

on_signal() {
    log 'Interruption recue ; abandon de la version incomplete.'
    exit 130
}

copy_source() {
    local src="$1" subdir="$2" previous="$3"
    local -a rsync_args=(-aAXH --numeric-ids --itemize-changes --stats)
    if [[ -n "$previous" ]]; then
        rsync_args+=("--link-dest=$previous/$subdir")
    fi
    mkdir -m 0700 -- "$STAGING_DIR/$subdir"
    log "Copie de $src vers la nouvelle version ($subdir)."
    rsync "${rsync_args[@]}" -- "$src/" "$STAGING_DIR/$subdir/"
    verify_mount
}

apply_retention() {
    local -a snapshots=()
    local d excess index
    mapfile -t snapshots < <(list_valid_snapshots)
    excess=$(( ${#snapshots[@]} - RETENTION_COUNT ))
    if (( excess <= 0 )); then
        log "Retention : ${#snapshots[@]} version(s) valide(s), aucune suppression."
        return 0
    fi
    for ((index = 0; index < excess; index++)); do
        d="${snapshots[$index]}"
        verify_mount
        [[ "$d" == "$SNAPSHOTS_DIR/"* && "$d" != "$SNAPSHOTS_DIR" && ! -L "$d" \
           && -f "$d/.complete" ]] || fail "Version a purger invalide : $d"
        log "Retention : suppression de l ancienne version ${d##*/}."
        rm -rf --one-file-system -- "$d"
    done
}

main() {
    require_root
    require_tools
    init_logging
    trap 'on_exit "$?"' EXIT
    trap on_signal INT TERM HUP
    log 'DEBUT sauvegarde BioLab.'
    load_config

    # Verrou avant toutes les operations sur les versions.
    exec 9>"$LOCK_FILE"
    flock -n 9 || fail 'Une autre sauvegarde est en cours (flock).'
    verify_mount
    check_capacity
    prepare_directories

    local previous=''
    local -a snapshots=()
    mapfile -t snapshots < <(list_valid_snapshots)
    if ((${#snapshots[@]} > 0)); then
        previous="${snapshots[${#snapshots[@]}-1]}"
        log "Version precedente : ${previous##*/}."
    fi

    VERSION="$(date '+%Y%m%d_%H%M%S_%N')"
    STAGING_DIR="$BACKUP_MOUNT/.incomplete/$VERSION"
    [[ ! -e "$STAGING_DIR" && ! -e "$SNAPSHOTS_DIR/$VERSION" ]] || fail 'Collision de nom de version.'
    verify_mount
    mkdir -m 0700 -- "$STAGING_DIR"
    copy_source '/srv' 'srv' "$previous"
    copy_source '/etc' 'etc' "$previous"

    verify_mount
    [[ -d "$STAGING_DIR/srv" && -d "$STAGING_DIR/etc" ]] || fail 'Sources incompletes dans la version.'
    printf '%s\n' "BioLab backup: $VERSION" >"$STAGING_DIR/.complete"
    chmod 0640 "$STAGING_DIR/.complete"
    # Seul le conteneur de la version est accessible au groupe admins.
    chown root:"$GROUP" "$STAGING_DIR"
    chmod 0750 "$STAGING_DIR"
    sync -f "$STAGING_DIR"
    verify_mount
    mv -T -- "$STAGING_DIR" "$SNAPSHOTS_DIR/$VERSION"
    STAGING_DIR=''
    sync -f "$SNAPSHOTS_DIR"
    COMPLETED=1
    log "Version publiee : $SNAPSHOTS_DIR/$VERSION."
    apply_retention
}

main "$@"
