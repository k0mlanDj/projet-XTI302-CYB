# XTI302-CYB — Lot BioLab B1 a B4

Responsable de ce lot : Malek Boufaied.

**Etat :** scripts livres et tests isoles de mecanique rsync reussis ; installation, restauration et ACL **a valider sur la VM**. Le disque `/dev/vdb` est non prepare selon la collecte du 04/11/2026.

## Livrables

- `sauvegarde.sh` : sauvegarde securisee de `/srv` et `/etc`, incrementalisee et 7 versions, journaux, verrou, verification du disque (B1-B3).
- `restaurer_sauvegarde.sh` : restauration d'un fichier ou dossier **sans ecraser les donnees reelles** (B4).
- `config/backup/backup.conf.example` : modele sans UUID sensible.
- `config/backup/biolab-sauvegarde.service` et `biolab-sauvegarde.timer` : execution systemd quotidienne.
- `docs/ARCHITECTURE.md` : justification, mecanisme, securite et limites des 2 Gio.
- `docs/PREPARATION_DISQUE.md` : preparation **manuelle, dangereuse si mauvais disque** et installation.
- `docs/RESTAURATION.md` : extraction controlee, verification, simulation de remise en production.
- `docs/INTEGRATION_GIT.md` : interface avec `installer.sh`/`verifier.sh`, commits et Pull Request.
- `tests/test_rsync_isole.sh` : tests sans disque reel ni modification de donnees BioLab.
- `tests/SCENARIOS_VM.md` : scenarios reproductibles B1-B4 sur la VM apres installation.
- `tests/RESULTATS_REELS.md` : controles et limites effectifs du travail livre.

**Ordre recommande :** lire `ARCHITECTURE.md` -> verifier le disque avec `PREPARATION_DISQUE.md` -> installer les scripts -> executer `SCENARIOS_VM.md` -> transmettre `INTEGRATION_GIT.md` a l'integrateur.

**Interdit dans le script principal :** `fdisk`, `mkfs`, creation de partition, auto-montage, modification de `fstab`, effacement des sources.

Aucune modification n'a ete faite aux scripts `creer_comptes.sh`, `analyse_logs.sh`, `installer.sh`, `verifier.sh` ou aux fichiers de durcissement des autres membres.
