# Scenarios de tests B1-B4 sur Debian 13 (a executer apres preparation du disque)

**Ces commandes ne sont pas des resultats observes.** Ne pas les executer en production sans accord de l'integrateur. Utiliser un clone/snapshot de la VM de reference pour les tests de retention, erreur de montage et interruption.

## Precontrole, aucune ecriture

```bash
bash -n sauvegarde.sh
bash -n restaurer_sauvegarde.sh
systemd-analyze verify config/backup/biolab-sauvegarde.service config/backup/biolab-sauvegarde.timer
lsblk -f
findmnt -M /mnt/biolab-backups -o SOURCE,TARGET,FSTYPE,UUID
sudo du -sh /srv /etc
sudo df -h /mnt/biolab-backups
sudo stat -c '%U:%G %a %n' /mnt/biolab-backups /mnt/biolab-backups/snapshots
```

## B1 / B2 : test controle

> Ces commandes creent volontairement un petit repertoire de test dans `/srv`. Elles ne modifient pas les donnees BioLab existantes.

```bash
sudo mkdir -p /srv/biolab-test-backup
printf 'VERSION_1\n' | sudo tee /srv/biolab-test-backup/exemple.txt >/dev/null
sudo chmod 640 /srv/biolab-test-backup/exemple.txt
sudo setfacl -m u:technique1:r-- /srv/biolab-test-backup/exemple.txt
sudo setfattr -n user.biolab -v 'test-xattr' /srv/biolab-test-backup/exemple.txt
sudo /usr/local/sbin/biolab-sauvegarde
sudo tail -n 25 /var/log/biolab-backups/sauvegarde.log
sudo ls -lt /mnt/biolab-backups/snapshots
```

Relever la derniere version :

```bash
sudo find /mnt/biolab-backups/snapshots -mindepth 1 -maxdepth 1 -type d -name '20*' -printf '%f\n' | sort
```

Noter a la main `V1=...`. Comparer droits, ACL, xattr et liens :

```bash
sudo stat -c '%u:%g %a %n' /srv/biolab-test-backup/exemple.txt /mnt/biolab-backups/snapshots/V1/srv/biolab-test-backup/exemple.txt
sudo getfacl -cp /srv/biolab-test-backup/exemple.txt
sudo getfacl -cp /mnt/biolab-backups/snapshots/V1/srv/biolab-test-backup/exemple.txt
sudo getfattr -d /srv/biolab-test-backup/exemple.txt
sudo getfattr -d /mnt/biolab-backups/snapshots/V1/srv/biolab-test-backup/exemple.txt
sudo test -d /mnt/biolab-backups/snapshots/V1/etc && echo '/etc sauve'
```

Lancer une seconde copie sans modifier le fichier. Noter `V2=...`, puis comparer inodes :

```bash
sudo /usr/local/sbin/biolab-sauvegarde
sudo stat -c '%i %h %n' /mnt/biolab-backups/snapshots/V1/srv/biolab-test-backup/exemple.txt /mnt/biolab-backups/snapshots/V2/srv/biolab-test-backup/exemple.txt
```

**Attendu :** memes inodes si le fichier et ses metadonnees sont inchanges. Puis :

```bash
printf 'VERSION_2\n' | sudo tee /srv/biolab-test-backup/exemple.txt >/dev/null
sudo /usr/local/sbin/biolab-sauvegarde
sudo cat /mnt/biolab-backups/snapshots/V2/srv/biolab-test-backup/exemple.txt
sudo cat /mnt/biolab-backups/snapshots/V3/srv/biolab-test-backup/exemple.txt
sudo stat -c '%i %n' /mnt/biolab-backups/snapshots/V2/srv/biolab-test-backup/exemple.txt /mnt/biolab-backups/snapshots/V3/srv/biolab-test-backup/exemple.txt
```

**Attendu :** V2 garde VERSION_1, V3 contient VERSION_2 et a un nouvel inode pour ce fichier.

## B2 : retention (clone ou disque de test uniquement)

Sur **un clone** et avec seulement des donnees de test : effectuer 8 a 9 sauvegardes reussies, puis :

```bash
sudo find /mnt/biolab-backups/snapshots -mindepth 1 -maxdepth 1 -type d -name '20*' -printf '%f\n' | sort
sudo find /mnt/biolab-backups/snapshots -mindepth 1 -maxdepth 1 -type d -name '20*' | wc -l
```

**Attendu :** 7 versions valides si `RETENTION_COUNT=7`, et les plus anciennes ont ete supprimees. Attention : lancer les 8 executions sur un vrai disque de sauvegarde effacerait les anciennes versions conformement a la retention : **ne pas le faire en production pour un simple test**.

## B3 : service / timer / erreurs

```bash
systemctl status biolab-sauvegarde.timer
systemctl list-timers --all | grep biolab-sauvegarde
sudo systemctl start biolab-sauvegarde.service
sudo systemctl status biolab-sauvegarde.service
sudo tail -n 80 /var/log/biolab-backups/sauvegarde.log
sudo journalctl -u biolab-sauvegarde.service -n 80 --no-pager
```

Sur clone **uniquement** : arreter timer, demonter proprement le disque, appeler manuellement le script, verifier code non-zero, confirmer qu'aucun `snapshots` n'a ete cree sur la partition systeme, puis remonter le disque. Ne pas forcer un demontage si le disque est utilise.

## B4 : restauration d'un fichier ET dossier

```bash
sudo /usr/local/sbin/biolab-restaurer V2 srv/biolab-test-backup/exemple.txt
sudo cmp /mnt/biolab-backups/snapshots/V2/srv/biolab-test-backup/exemple.txt /var/tmp/biolab-restauration/V2/srv/biolab-test-backup/exemple.txt
sudo /usr/local/sbin/biolab-restaurer V3 srv/biolab-test-backup
sudo getfacl -cp /mnt/biolab-backups/snapshots/V3/srv/biolab-test-backup/exemple.txt
sudo getfacl -cp /var/tmp/biolab-restauration/V3/srv/biolab-test-backup/exemple.txt
```

Restaurer une deuxieme fois le **meme** chemin de version : **attendu : refus d'ecrasement**.

## B4 : tests d'acces (a faire avec l'integrateur)

```bash
sudo namei -l /mnt/biolab-backups/snapshots
sudo stat -c '%U:%G %a %n' /mnt/biolab-backups /mnt/biolab-backups/snapshots
sudo runuser -u malek.boufaied -- test -x /mnt/biolab-backups/snapshots && echo 'admin : traversable'
sudo runuser -u technique1 -- test -x /mnt/biolab-backups/snapshots && echo 'ERREUR : acces technique' || echo 'OK : technique refuse'
sudo runuser -u chercheur1 -- test -x /mnt/biolab-backups/snapshots && echo 'ERREUR : acces chercheur' || echo 'OK : chercheur refuse'
sudo runuser -u doctorant1 -- test -x /mnt/biolab-backups/snapshots && echo 'ERREUR : acces doctorant' || echo 'OK : doctorant refuse'
sudo runuser -u support -- test -x /mnt/biolab-backups/snapshots && echo 'ERREUR : acces support' || echo 'OK : support refuse'
sudo runuser -u invite1 -- test -x /mnt/biolab-backups/snapshots && echo 'ERREUR : acces invite' || echo 'OK : invite refuse'
```

Une authentification n'est pas requise ici : `runuser` lance la commande avec l'identite du compte, meme pour un compte n'ayant pas de shell interactif.

## Nettoyage des donnees de test uniquement

Apres validation (et en ayant confirme le chemin exact) :

```bash
sudo rm -rf -- /srv/biolab-test-backup
sudo rm -rf -- /var/tmp/biolab-restauration
```

**Ne pas supprimer manuellement des versions du disque de sauvegarde**, surtout pas celles partageant des hardlinks.
