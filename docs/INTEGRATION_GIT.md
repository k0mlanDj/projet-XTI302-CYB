# A l'attention de l'integrateur — commandes et interfaces

## Dependances / installations

- Paquets : `rsync`, `acl`, `attr`, `util-linux` (`flock`, `findmnt`), `e2fsprogs` (`blkid`, `mkfs.ext4`), `systemd`.
- Scripts deployes (root:root 0750) : `sauvegarde.sh` -> `/usr/local/sbin/biolab-sauvegarde`, `restaurer_sauvegarde.sh` -> `/usr/local/sbin/biolab-restaurer`.
- Configuration root locale (root:root 0640) : `config/backup/backup.conf.example` -> `/etc/biolab-backup.conf`, puis renseigner l'UUID **reel**.
- Unites (root:root 0644) : `config/backup/biolab-sauvegarde.service` et `.timer` -> `/etc/systemd/system/`, puis `systemctl daemon-reload` et `systemctl enable --now biolab-sauvegarde.timer`.
- Disque : preparation **manuelle** et supervision : voir `PREPARATION_DISQUE.md`. L'installateur ne doit **jamais** appeler `fdisk`, `parted`, `mkfs`, `mount` ni modifier `fstab` sans validation interactive explicite.
- `/mnt/biolab-backups` : root:admins 0750 **sur le disque monte**. `/var/log/biolab-backups` : root:admins 0750. `/var/log/biolab-backups/sauvegarde.log` : root:admins 0640.
- Le depot dans `/home/biolab-admin` est modifiable : **ne jamais lancer directement le fichier Git avec root depuis un service systemd** ; le copier en `/usr/local/sbin/` root:root avant activation du timer.

## Extraits a integrer plus tard a `installer.sh`

Prevoir dans l'ordre : controle root, `apt install -y rsync acl attr util-linux e2fsprogs`, verifications disque, confirmation explicite que **le disque a deja ete prepare**, controle du groupe admins, puis commandes `install` et `systemctl` de `PREPARATION_DISQUE.md`.

Ne pas tenter de deviner l'UUID ni de rendre le script interactif pendant une execution du timer.

## Controles a integrer plus tard a `verifier.sh`

- `command -v rsync`, `getfacl`, `setfacl`, `getfattr`, `findmnt`, `flock`.
- `bash -n` sur les deux scripts.
- `systemctl is-enabled biolab-sauvegarde.timer` et `systemctl list-timers`.
- `findmnt -M /mnt/biolab-backups -o SOURCE,FSTYPE,UUID` (vrai disque distinct de `/srv`).
- `stat` des chemins : dossier `snapshots` root:admins 0750 et journal root:admins 0640.
- Existence d'au moins une version **complete** avec `srv/`, `etc/` et `.complete`.
- Existence d'au moins 7 versions seulement **apres** 7 sauvegardes reussies ; ne pas exiger immediatement ce chiffre au premier jour.
- Un test de restauration a blanc (`biolab-restaurer ...`) et `rsync -n -aAXHc` sur un fichier non sensible de test, depuis une version valide.
- Tests de `runuser -u technique1/chercheur1/doctorant1/support/invite1` refus sur `snapshots`, et succes de traversee pour `malek.boufaied`.
- Verifier que `sauvegarde.sh` ne contient pas de `mkfs`, partitionnement ou `--delete` sur les sources.

## Git : ajouter uniquement les fichiers de la partie sauvegardes

Dans `/home/biolab-admin/projet-XTI302-CYB` sur la VM (preserver les fichiers d'autres membres) :

```bash
git status --short
git fetch origin
git switch -c feature/sauvegardes
# Copier uniquement les fichiers fournis vers les memes chemins du depot.
# Si les dossiers docs/tests contiennent deja des fichiers d'autres membres, ne pas les ecraser.
chmod 750 sauvegarde.sh restaurer_sauvegarde.sh
bash -n sauvegarde.sh && bash -n restaurer_sauvegarde.sh
git add -- README_B1_B4.md sauvegarde.sh restaurer_sauvegarde.sh \
  config/backup/backup.conf.example \
  config/backup/biolab-sauvegarde.service \
  config/backup/biolab-sauvegarde.timer \
  docs/ARCHITECTURE.md docs/PREPARATION_DISQUE.md \
  docs/RESTAURATION.md docs/INTEGRATION_GIT.md \
  tests/test_rsync_isole.sh tests/SCENARIOS_VM.md tests/RESULTATS_REELS.md
git diff --cached --stat
git diff --cached --check
git commit -m "feat(backup): ajouter sauvegardes incrementales et restauration BioLab"
git push -u origin feature/sauvegardes
```

Ouvrir ensuite la Pull Request :

```bash
gh auth status
gh pr create --base main --head feature/sauvegardes \
  --title "B1-B4 - Sauvegarde incrementale et restauration BioLab" \
  --body "Scripts de sauvegarde et restauration, timer systemd, procedure disque et scenarios de verification. Aucun formatage automatique. Tests VM reels a effectuer apres montage du disque."
```

Si `gh` n'est pas installe, ouvrir sur GitHub le depot `k0mlanDj/projet-XTI302-CYB`, choisir la branche `feature/sauvegardes`, puis **Compare & pull request** vers `main`.

**Ne pas** executer `git add .` ou `git add -A` : des fichiers non suivis (`installer.sh`, `verifier.sh`, `analyse_logs.sh`, `README.md`, `DOSSIER.md`) appartiennent aux autres membres et ne doivent pas etre embarques. **Ne jamais ajouter** `/etc/biolab-backup.conf`, journaux, donnees sauvegardees, mots de passe ou cles privees.
