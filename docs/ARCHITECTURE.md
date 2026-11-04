# Architecture B1-B4 — BioLab

## Constat initial au 04/11/2026

- Debian 13.7, serveur `Debian13-BioLab`.
- `/dev/vda1` racine, `/dev/vda5` `/var`, `/dev/vda7` `/srv`.
- `/dev/vdb` : disque secondaire de 2 Gio (annonce VM « 2G »), **sans partition, sans systeme de fichiers et non monte**.
- `/srv` (partition ~11,7 Gio) : environ 2,1 Mio utilises lors de la collecte.
- `/etc` : taille non relevee dans l'archive ; la mesurer sur la VM.
- `rsync` n'apparait pas dans la liste des paquets utiles collectes : verifier sa disponibilite et l'installer si necessaire.
- Groupe `admins` present : `komlan.djadou`, `hugo.boukria`, `malek.boufaied`.
- Les ACL de `/srv/donnees_brutes`, `/srv/analyses`, `/srv/publications` doivent survivre aux sauvegardes/restaurations.
- Le depot possede des scripts vides `sauvegarde.sh`, `installer.sh`, `verifier.sh` ; ceux des autres membres restent inchanges.

**Source prioritaire indisponible :** le PDF exact du sujet n'etait pas inclus dans les fichiers du present envoi. Le developpement respecte le document de mission B1-B4 et l'archive d'etat des lieux ; valider le resultat avec le PDF original avant livraison finale au professeur.

## Organisation

- Dans Git : `sauvegarde.sh`, `restaurer_sauvegarde.sh`, `config/backup/`, `docs/`, `tests/`.
- Programme executable **installe** : `/usr/local/sbin/biolab-sauvegarde`, root:root 0750.
- Programme restauration **installe** : `/usr/local/sbin/biolab-restaurer`, root:root 0750.
- Configuration root : `/etc/biolab-backup.conf`, root:root 0640 (copie de `config/backup/backup.conf.example` en renseignant l'UUID).
- Disque de sauvegarde : `/dev/vdb1` ext4 (seulement apres verification et preparation manuelle) monte en `/mnt/biolab-backups`.
- Journaux : `/var/log/biolab-backups/sauvegarde.log`, dossier root:admins 0750, fichier root:admins 0640.
- Verrou : `/run/lock/biolab-sauvegarde.lock` via `flock -n`.
- Planification : timer systemd quotidien a 02h30, avec `Persistent=true` (une execution manquee peut etre rattrapee apres redemarrage).

Apres installation, structure du disque :

```text
/mnt/biolab-backups/
├── .incomplete/                    # root uniquement ; copie temporaire
└── snapshots/                      # root:admins 0750
    ├── 20261104_023000_123456789/  # exemple de version valide
    │   ├── .complete               # marqueur pose apres rsync sans erreur
    │   ├── srv/                    # contenu de /srv, ACL et proprietaires
    │   └── etc/                    # contenu de /etc
    └── 20261105_023000_123456789/
        ├── .complete
        ├── srv/
        └── etc/
```

## B1 : preservation

`rsync -aAXH --numeric-ids` conserve la structure, les liens symboliques, dates, proprietaires, groupes, permissions (`-a`), les ACL (`-A`), attributs etendus (`-X`), liens physiques (`-H`), et les UID/GID numeriques sans conversion (`--numeric-ids`). L'execution sous root est necessaire pour preserver proprietaires et ACL correctement. Les fichiers speciaux crees par un root malveillant restent un risque du systeme source ; monter le disque avec `nodev,nosuid,noexec`.

`rsync -a` **seul** ne conserve ni toutes les ACL ni les xattrs.

## B2 : lien physique et copies incrementees

La premiere version copie les fichiers. Pour les suivantes, `rsync --link-dest=<version_precedente>/srv` ou `.../etc` compare chaque fichier a la version precedente : si contenu, horodatage et metadonnees pertinentes sont identiques, un **lien physique** (hard link) vers le meme inode du disque de sauvegarde remplace la recopie des octets. Si le fichier change, rsync cree un fichier distinct dans la nouvelle version. Toutes les versions semblent completes et peuvent etre restaurees independamment.

Les repertoires et liens symboliques ne sont pas partages comme des fichiers par hardlink. Ne **jamais modifier une version sauvegardee** : les fichiers inchanges peuvent etre partages entre plusieurs versions. Ne pas appliquer `chmod -R` aux versions publiees. Seules les suppressions des repertoires de versions, apres nouvelle sauvegarde reussie, sont autorisees.

La version est d'abord construite dans `.incomplete/` non accessible aux non-root. Apres retour zero des deux rsync et controle du montage, on cree `.complete`, puis on publie par `mv` atomique **sur le meme systeme de fichiers**. En cas d'echec ou d'interruption, la version n'est pas valide ; nettoyage conditionne a la presence du bon montage. Le script ne traite que les versions dont le nom et `.complete` sont valides.

Le script ne contient **pas** de `--delete` sur les sources. Il ne supprime que les **repertoires des versions du disque de sauvegarde** excedant la politique (7 versions par defaut). Les liens physiques rendent cette suppression sure pour les autres versions qui referencent encore les memes inodes.

## B3 : systemd et verrou

Le timer systemd est adapte au serveur Debian 13 : sa configuration est versionnee, il expose son etat avec `systemctl`, la derniere execution avec `systemctl status` et les erreurs avec un fichier de journal protege. `Persistent=true` prend en charge les executions manquees quand le serveur etait eteint. `flock -n` empeche deux sauvegardes en concurrence ; un appel manuel pendant l'execution du timer echoue proprement.

## B4 : restauration

La commande `biolab-restaurer VERSION srv/chemin` ou `etc/chemin` exige un nom de version daté valide, la presence de `.complete`, le bon disque monte, et un chemin sans `..` ou lien symbolique intermediaire. Elle produit une copie dans `/var/tmp/biolab-restauration/VERSION/` et refuse d'ecraser une destination existante. Elle ne restaure jamais directement `/srv` ni `/etc` ; une remise en production requiert une operation manuelle documentee.

## Controle d'acces

Les ancetres du dossier `snapshots` sont proteges : montage `root:admins 0750` et dossier `snapshots` `root:admins 0750`, versions `root:admins 0750`. Les sous-arbres `srv` et `etc` conservent les ACL et proprietaires des donnees d'origine. Cela peut limiter la lecture de certains fichiers aux membres `admins` qui ne sont pas root ; c'est intentionnel : les admins auront besoin d'une elevation legitime via C3, et le script de restauration s'execute sous root. Les membres des groupes `technique`, `chercheurs`, `doctorants`, `invite`, `support` ne peuvent pas traverser le dossier des versions.

Important : l'archive de collecte ne prouve pas que les permissions futures sont correctes. Verifier effectivement les tests d'acces sur la VM.

## Risques et limites du disque de 2 Gio

- `du -sh /srv /etc` mesure l'existant ; `/etc` n'etait pas chiffre dans l'archive.
- Les hardlinks reduisent enormement les doublons **si les fichiers restent inchanges** ; une forte rotation des donnees consomme vite l'espace.
- Les versions restent independantes, mais le disque doit contenir une copie de chaque fichier modifie encore present dans une des versions retenues.
- L'estimation `du` + 128 Mio libres est volontairement **conservatrice** : elle bloque parfois une copie incrementalisee qui aurait pourtant tenu. C'est une barriere de securite, pas une garantie absolue (donnees changeant pendant la copie, inode exhaustion, metadonnees, ext4 reserve).
- Le systeme verifie l'espace avant copie ; toute erreur `rsync` (y compris ENOSPC) laisse la version non publiee.
- Sept versions ne signifient pas sept **jours** si des executions manuelles ont lieu ; la retention est en **nombre de versions**, et non en jours.
- Le meme disque physique reste un point de defaillance. Cette sauvegarde **ne remplace pas** une copie hors machine / hors site.
- `rsync` ne fait pas de snapshot instantane de donnees en cours d'ecriture : la coherence des applications n'est pas garantie si leurs fichiers changent pendant l'execution. Pour ce laboratoire, planifier hors activite et tester.

## Plan de validation

1. Preparer le disque manuellement et monter ext4 sur UUID correct.
2. Installer les fichiers dans les chemins root et verifier `bash -n`.
3. Creer un **fichier de test isole** sous `/srv/`, executer sauvegarde, comparer droits, ACL, xattrs.
4. Faire deux sauvegardes inchangees, comparer inodes du fichier test.
5. Modifier le fichier de test, lancer une nouvelle sauvegarde, verifier les deux valeurs dans les versions distinctes.
6. Sur clone/VM de test, executer assez de sauvegardes pour tester la retention de sept versions.
7. Verifier `systemctl list-timers`, declenchement manuel et journaux.
8. Restaurer un fichier et un dossier sous `/var/tmp/biolab-restauration`, comparer contenu et ACL.
9. Tester les permissions avec les comptes `admins`, `technique1`, `chercheur1`, `doctorant1`, `support`, `invite1` (ce dernier n'a pas de shell : utiliser `runuser` depuis root).
10. Simuler l'absence de disque **sur une VM de test**, verifier code d'erreur et absence d'ecritures sous `/mnt/biolab-backups`.
