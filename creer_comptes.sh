#!/bin/bash

# ============================================================
# Projet XTI302-CYB - Laboratoire BioLab
# Script : creer_comptes.sh
# Objectif : création idempotente des comptes et groupes (C1)
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CSV_FILE="$SCRIPT_DIR/comptes.csv"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/creation_comptes.log"

if [[ "$EUID" -ne 0 ]]; then
    echo "ERREUR : exécuter ce script avec sudo." >&2
    exit 1
fi

if [[ ! -f "$CSV_FILE" ]]; then
    echo "ERREUR : comptes.csv introuvable." >&2
    exit 1
fi

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

valider_login() {
    [[ "$1" =~ ^[a-z_][a-z0-9._-]*$ ]]
}

valider_groupe() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]
}

creer_groupe() {
    local groupe="$1"

    if getent group "$groupe" >/dev/null; then
        log "Groupe déjà existant : $groupe"
    else
        groupadd "$groupe"
        log "Groupe créé : $groupe"
    fi
}

verifier_csv() {
    local ligne=0 login nom principal secondaires extra groupe
    local -a liste_secondaires
    local -A logins_vus=()

    while IFS=';' read -r login nom principal secondaires extra || [[ -n "${login:-}" ]]; do
        ((ligne += 1)) || true

        login="${login%$'\r'}"
        nom="${nom%$'\r'}"
        principal="${principal%$'\r'}"
        secondaires="${secondaires%$'\r'}"

        if (( ligne == 1 )); then
            [[ "$login;$nom;$principal;$secondaires" == \
                "login;nom;groupe_principal;groupes_secondaires" ]] || {
                log "ERREUR : en-tête CSV incorrect."
                return 1
            }
            continue
        fi

        if [[ -n "${extra:-}" || -z "$login" || -z "$nom" || -z "$principal" ]]; then
            log "ERREUR : nombre de colonnes ou champ obligatoire incorrect à la ligne $ligne."
            return 1
        fi

        valider_login "$login" || {
            log "ERREUR : login invalide : $login"
            return 1
        }

        valider_groupe "$principal" || {
            log "ERREUR : groupe principal invalide : $principal"
            return 1
        }

        [[ ! ${logins_vus[$login]+_} ]] || {
            log "ERREUR : login dupliqué : $login"
            return 1
        }
        logins_vus["$login"]=1

        if [[ -n "$secondaires" ]]; then
            IFS=',' read -r -a liste_secondaires <<< "$secondaires"

            for groupe in "${liste_secondaires[@]}"; do
                valider_groupe "$groupe" || {
                    log "ERREUR : groupe secondaire invalide : $groupe"
                    return 1
                }

                [[ "$groupe" != "$principal" ]] || {
                    log "ERREUR : groupe principal répété comme secondaire pour $login."
                    return 1
                }
            done
        fi

    done < "$CSV_FILE"

    (( ligne >= 2 )) || {
        log "ERREUR : aucun compte dans le CSV."
        return 1
    }

    log "Validation CSV réussie : ${#logins_vus[@]} comptes."
}

traiter_groupes() {
    local login nom principal secondaires extra groupe
    local -a liste_secondaires

    while IFS=';' read -r login nom principal secondaires extra || [[ -n "${login:-}" ]]; do
        [[ "$login" == "login" ]] && continue

        principal="${principal%$'\r'}"
        secondaires="${secondaires%$'\r'}"

        creer_groupe "$principal"

        if [[ -n "$secondaires" ]]; then
            IFS=',' read -r -a liste_secondaires <<< "$secondaires"

            for groupe in "${liste_secondaires[@]}"; do
                creer_groupe "$groupe"
            done
        fi
    done < "$CSV_FILE"
}

traiter_utilisateurs() {
    local login nom principal secondaires extra shell home_dir
    local -a liste_secondaires

    while IFS=';' read -r login nom principal secondaires extra || [[ -n "${login:-}" ]]; do
        [[ "$login" == "login" ]] && continue

        login="${login%$'\r'}"
        principal="${principal%$'\r'}"
        secondaires="${secondaires%$'\r'}"

        # Les comptes invités ne disposent pas d'un shell interactif.
        if [[ "$principal" == "invite" ]]; then
            shell="/usr/sbin/nologin"
        else
            shell="/bin/bash"
        fi

        if id "$login" >/dev/null 2>&1; then
            log "Compte existant : $login"

            if [[ -n "$secondaires" ]]; then
                usermod -g "$principal" -G "$secondaires" -s "$shell" "$login"
            else
                usermod -g "$principal" -G "" -s "$shell" "$login"
            fi

            log "Groupes et shell mis à jour : $login"
        else
            if [[ -n "$secondaires" ]]; then
                useradd -m -N -g "$principal" -G "$secondaires" \
                    -s "$shell" "$login"
            else
                useradd -m -N -g "$principal" \
                    -s "$shell" "$login"
            fi

            log "Compte créé : $login"
        fi

        home_dir="$(getent passwd "$login" | cut -d: -f6)"

        if [[ -z "$home_dir" || "$home_dir" == "/" ]]; then
            log "ERREUR : répertoire personnel invalide pour $login."
            return 1
        fi

        install -d -m 700 -o "$login" -g "$principal" "$home_dir"
        log "Répertoire personnel sécurisé : $home_dir"

    done < "$CSV_FILE"
}

# Configuration des espaces de données BioLab (C2)

# Installation des clés SSH publiques (C1)
installer_cles_ssh() {
    local repertoire_cles="$SCRIPT_DIR/config/ssh-keys"
    local repertoire_cibles="/etc/ssh/authorized_keys"

    local -A correspondance=(
        [komlan.djadou]="komlan_djadou_ed25519.pub"
        [hugo.boukria]="hugo_boukria_ed25519.pub"
        [malek.boufaied]="malek_boufaied_ed25519.pub"
        [support]="support_ed25519.pub"
        [invite1]="invite1_ed25519.pub"
        [invite2]="invite2_ed25519.pub"
    )

    command -v ssh-keygen >/dev/null 2>&1 || {
        log "ERREUR : ssh-keygen absent."
        return 1
    }

    install -d -o root -g root -m 755 "$repertoire_cibles"

    for login in "${!correspondance[@]}"; do
        local fichier="$repertoire_cles/${correspondance[$login]}"
        local destination="$repertoire_cibles/$login"

        if ! id "$login" >/dev/null 2>&1; then
            log "ERREUR : compte SSH inexistant : $login"
            return 1
        fi

        if [[ ! -f "$fichier" ]] || ! ssh-keygen -lf "$fichier" >/dev/null 2>&1; then
            log "ERREUR : clé publique absente ou invalide : $fichier"
            return 1
        fi

        install -o root -g root -m 600 "$fichier" "$destination"

        log "Clé SSH installée pour : $login"
    done

    log "Installation des six clés SSH terminée."
}


configurer_repertoires_biolab() {
    local repertoire groupe

    # Vérification des outils ACL
    for outil in setfacl getfacl; do
        if ! command -v "$outil" >/dev/null 2>&1; then
            log "ERREUR : outil requis absent : $outil"
            return 1
        fi
    done

    # Vérification des groupes nécessaires
    for groupe in technique chercheurs doctorants invite; do
        if ! getent group "$groupe" >/dev/null; then
            log "ERREUR : groupe requis absent : $groupe"
            return 1
        fi
    done

    # Création des répertoires, propriété root:root
    for repertoire in donnees_brutes analyses publications; do
        install -d -o root -g root -m 700 "/srv/$repertoire"
        log "Répertoire vérifié : /srv/$repertoire"
    done

    # Données brutes : technique RWX, chercheurs RX, doctorants RX
    setfacl -m \
    u::rwx,g::---,g:technique:rwx,g:chercheurs:r-x,g:doctorants:r-x,m::rwx,o::--- \
    /srv/donnees_brutes

    setfacl -d -m \
    u::rwx,g::---,g:technique:rwx,g:chercheurs:r-x,g:doctorants:r-x,m::rwx,o::--- \
    /srv/donnees_brutes

    # Analyses : chercheurs et doctorants RWX
    setfacl -m \
    u::rwx,g::---,g:chercheurs:rwx,g:doctorants:rwx,m::rwx,o::--- \
    /srv/analyses

    setfacl -d -m \
    u::rwx,g::---,g:chercheurs:rwx,g:doctorants:rwx,m::rwx,o::--- \
    /srv/analyses

    # Publications : chercheurs RWX, doctorants et invités RX
    setfacl -m \
    u::rwx,g::---,g:chercheurs:rwx,g:doctorants:r-x,g:invite:r-x,m::rwx,o::--- \
    /srv/publications

    setfacl -d -m \
    u::rwx,g::---,g:chercheurs:rwx,g:doctorants:r-x,g:invite:r-x,m::rwx,o::--- \
    /srv/publications

    # Vérification de la présence des ACL par défaut
    for repertoire in donnees_brutes analyses publications; do
        if ! getfacl -cp "/srv/$repertoire" | grep -q '^default:other::---$'; then
            log "ERREUR : ACL par défaut incorrecte sur /srv/$repertoire"
            return 1
        fi
    done

    log "Configuration des répertoires BioLab et des ACL terminée."
}

main() {
    log "Début du traitement des comptes BioLab."

    # Aucune modification avant validation complète du CSV.
    verifier_csv

    # Les groupes sont créés avant les utilisateurs.
    traiter_groupes

    # Création et mise à jour des comptes.
    traiter_utilisateurs

    # Installation des clés publiques SSH (C1).
    installer_cles_ssh

    # Configuration des répertoires et ACL (C2).
    configurer_repertoires_biolab

    # Verrouillage du compte root (C4).
    passwd -l root
    log "Compte root verrouillé."

    log "Traitement des comptes terminé avec succès."
}

main "$@"
