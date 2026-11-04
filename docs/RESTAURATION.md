# Procedure de restauration B4 (controlee)

La restauration **commence toujours par une copie de test**, sans toucher aux donnees existantes. Le script `biolab-restaurer` s'execute sous root, refuse les chemins traversant des liens symboliques intermediaires et refuse les destinations de test existantes.

## 1. Choisir une version complete

```bash
sudo ls -la /mnt/biolab-backups/snapshots/
sudo test -f /mnt/biolab-backups/snapshots/VERSION/.complete && echo VERSION_VALIDE
```

Remplacer `VERSION` par une version reelle, exemple `20261104_163000_123456789`. La verification de l'UUID du montage est aussi faite automatiquement par le script.

## 2. Restaurer un fichier **dans le dossier de test**

```bash
sudo /usr/local/sbin/biolab-restaurer VERSION srv/analyses/fichier-de-test.txt
sudo ls -l /var/tmp/biolab-restauration/VERSION/srv/analyses/fichier-de-test.txt
sudo getfacl -p /mnt/biolab-backups/snapshots/VERSION/srv/analyses/fichier-de-test.txt
sudo getfacl -p /var/tmp/biolab-restauration/VERSION/srv/analyses/fichier-de-test.txt
sudo cmp /mnt/biolab-backups/snapshots/VERSION/srv/analyses/fichier-de-test.txt \
    /var/tmp/biolab-restauration/VERSION/srv/analyses/fichier-de-test.txt
```

## 3. Restaurer un repertoire **dans le dossier de test**

```bash
sudo /usr/local/sbin/biolab-restaurer VERSION srv/analyses/test-heritage
sudo rsync -n -aAXHc --numeric-ids --itemize-changes \
   /mnt/biolab-backups/snapshots/VERSION/srv/analyses/test-heritage/ \
   /var/tmp/biolab-restauration/VERSION/srv/analyses/test-heritage/
```

Le `rsync -n -aAXHc` final ne doit rien signaler de different (il compare aussi le contenu par checksum). Attention : cette commande lit les donnees mais ne les modifie pas.

## 4. Remise en production (MANUELLE seulement apres validation)

**Ne pas executer automatiquement.** D'abord une nouvelle sauvegarde des fichiers actuels, confirmer le chemin exact et faire relire le plan par l'administrateur autorise. Pour un **nouveau chemin absent**, on peut envisager une copie `rsync -aAXHn --numeric-ids` (simulation), puis `rsync -aAXH --numeric-ids` apres validation. Pour **remplacer un chemin existant**, mettre l'original a l'abri dans une copie de secours protege, puis valider explicitement le remplacement ; ne pas utiliser `--delete` a l'aveugle.

Exemple de simulation uniquement, sur un fichier test :

```bash
sudo rsync -n -aAXH --numeric-ids --itemize-changes \
  /var/tmp/biolab-restauration/VERSION/srv/analyses/fichier-de-test.txt \
  /srv/analyses/fichier-de-test.txt
```

Ne jamais lancer cet exemple pour `/etc` complet : une restauration de configurations systeme doit etre ciblee, controlee et eventuellement suivie d'une validation et d'un redemarrage des services concernes.

## 5. Controles des metadonnees

```bash
sudo stat -c '%u:%g %a %n' CHEMIN_SOURCE CHEMIN_RESTAURE
sudo getfacl -cp CHEMIN_SOURCE
sudo getfacl -cp CHEMIN_RESTAURE
sudo getfattr -d -m - CHEMIN_SOURCE 2>/dev/null || true
sudo getfattr -d -m - CHEMIN_RESTAURE 2>/dev/null || true
```

Les noms de proprietaires peuvent varier apres recuperation sur une autre machine : comparer les **UID/GID numeriques** quand la preservation est critique.
