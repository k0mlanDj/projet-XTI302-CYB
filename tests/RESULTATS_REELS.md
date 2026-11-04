# Resultats reels — etat au 04/11/2026

**Contexte de test :** environnement isole de preparation du livrable, **pas** la VM de reference `Debian13-BioLab` et **pas** le disque `/dev/vdb`. Aucun formatage, montage, partitionnement ni modification de `/srv` ou `/etc` de la VM BioLab n'a ete effectue.

## Executions observees

1. `bash -n sauvegarde.sh` : **OK** (aucune erreur de syntaxe).
2. `bash -n restaurer_sauvegarde.sh` : **OK** (aucune erreur de syntaxe).
3. `bash -n tests/test_rsync_isole.sh` : **OK**.
4. `rsync --version` : rsync 3.4.1 disponible dans le conteneur de validation.
5. `rsync --help` : options `--acls (-A)`, `--xattrs (-X)`, `--hard-links (-H)`, `--numeric-ids`, `--link-dest` disponibles.
6. `tests/test_rsync_isole.sh` : **OK**. Sortie exacte :

```text
OK : lien physique (inode commun pour version inchangee).
OK : mode 0640, lien symbolique et liens physiques preserves.
OK : attribut etendu user.biolab preserve.
OK : fichier modifie independant, historique v2 intact.
OK : restauration isolee et contenu identique.
NON TESTE : ACL nommees (outils setfacl/getfacl absents localement).
RESULTAT LOCAL : TESTS D INCREMENTATION ET DE RESTAURATION REUSSIS.
```

7. `systemd-analyze verify` : analyse de syntaxe des fichiers d'unite possible, mais dans cet environnement le service n'est **pas installe** sous `/usr/local/sbin/biolab-sauvegarde`. La verification a signale le binaire absent ; ce n'est pas une verification de l'activation du timer BioLab.

## Tests non realises et non revendiques

- Preparation/montage du disque `/dev/vdb1` sur la VM : **NON REALISE**.
- Execution integrale de `sauvegarde.sh` sur la VM : **NON REALISEE**.
- Conservation des ACL nommees (getfacl/setfacl) : **NON TESTEE localement**.
- Verification reelle des droits de `admins`, `technique`, `chercheurs`, `doctorants`, `invite`, `support` : **NON REALISEE**.
- Retention automatique de sept versions via le **script de production** : **NON TESTEE** (necessite un disque prepare ou un clone de la VM).
- Timer systemd installe et declenche sur Debian 13 : **NON TESTE**.
- Refus de lancement en cas de disque demonte, restauration via `biolab-restaurer` et code de retour sur VM : **NON TESTES**.

## Pour obtenir les resultats sur la VM

Se reporter a `SCENARIOS_VM.md`, collecter commandes + sorties (captures si demandees), et mettre a jour ce fichier **uniquement avec les resultats effectivement observes**.
