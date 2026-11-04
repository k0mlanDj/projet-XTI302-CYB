# Preparation du disque — PROCEDURE MANUELLE (jamais dans sauvegarde.sh)

**DANGER : partitionner/formater efface le disque cible.** Les operations ci-dessous ne sont destinees qu'au disque secondaire neuf et vide confirme **sur la VM BioLab**. Effectuer un instantane de la VM avant de commencer. Ne rien executer tant que l'identite du disque n'est pas certaine.

## 1. Verifications non destructives

```bash
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,UUID
sudo fdisk -l /dev/vdb
sudo wipefs -n /dev/vdb
sudo blkid
findmnt -M /srv -o SOURCE,TARGET,FSTYPE,UUID
```

Comparer avec l'etat des lieux : `/dev/vda` = disque SYSTEME ; `/dev/vdb` = disque secondaire **2G** (vide a la collecte). Si `/dev/vdb` contient des partitions, une signature ou des donnees inattendues, **STOP** et validation humaine. Aucune commande de preparation ci-dessous n'est automatique.

## 2. Partitionner uniquement apres validation

```bash
sudo fdisk /dev/vdb
```

Dans l'outil interactif `fdisk`, sur le disque **confirme** `/dev/vdb` : `g` (nouvelle table GPT), `n` (nouvelle partition, accepter les valeurs par defaut), `p` (relire la table), puis `w` pour enregistrer. **Attention : `g` et `w` sont destructifs sur tout contenu preexistant.** Si doute, `q` pour quitter sans rien ecrire.

Verifier ensuite :

```bash
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,UUID /dev/vdb
```

N'aller plus loin que si la nouvelle partition est bien `/dev/vdb1`.

## 3. Formater la nouvelle partition (explicite, destructif)

```bash
sudo mkfs.ext4 -L BIOLAB_BACKUP /dev/vdb1
sudo blkid /dev/vdb1
```

Noter l'**UUID reel** affiche. Ne copier **aucun** UUID du disque systeme donne dans l'etat des lieux.

## 4. Montage permanent controle

```bash
sudo mkdir -p /mnt/biolab-backups
sudo cp -a /etc/fstab /etc/fstab.avant-biolab-backup
sudo nano /etc/fstab
```

Ajouter **une seule ligne** en remplaçant `UUID_REEL_DE_VDB1` par l'UUID verifie :

```fstab
UUID=UUID_REEL_DE_VDB1 /mnt/biolab-backups ext4 defaults,nofail,nodev,nosuid,noexec 0 2
```

Puis :

```bash
sudo systemctl daemon-reload
sudo mount /mnt/biolab-backups
findmnt -M /mnt/biolab-backups -o TARGET,SOURCE,FSTYPE,UUID,OPTIONS
lsblk -f /dev/vdb
sudo chown root:admins /mnt/biolab-backups
sudo chmod 750 /mnt/biolab-backups
sudo mount -a
```

**Important :** `nofail` permet au serveur de demarrer sans ce disque, mais **le script refusera toute sauvegarde** s'il est absent. Ne pas installer le timer avant d'avoir valide le montage.

## 5. Dependances et configuration (depuis le dossier du depot)

```bash
sudo apt update
sudo apt install -y rsync acl attr util-linux e2fsprogs
command -v rsync getfacl setfacl flock findmnt blkid
sudo install -o root -g root -m 0640 config/backup/backup.conf.example /etc/biolab-backup.conf
sudo nano /etc/biolab-backup.conf
```

Dans le fichier **hors Git**, renseigner `BACKUP_UUID=<UUID_reel_de_vdb1>` ; verifier `BACKUP_DEVICE=/dev/vdb1`. Attention : si le disque est reconnu sous un autre nom au prochain demarrage, ajuster `BACKUP_DEVICE` sous controle ; l'UUID reste le controle principal.

```bash
sudo chown root:root /etc/biolab-backup.conf
sudo chmod 640 /etc/biolab-backup.conf
sudo install -o root -g root -m 0750 sauvegarde.sh /usr/local/sbin/biolab-sauvegarde
sudo install -o root -g root -m 0750 restaurer_sauvegarde.sh /usr/local/sbin/biolab-restaurer
sudo install -o root -g root -m 0644 config/backup/biolab-sauvegarde.service /etc/systemd/system/
sudo install -o root -g root -m 0644 config/backup/biolab-sauvegarde.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo /usr/local/sbin/biolab-sauvegarde
sudo tail -n 40 /var/log/biolab-backups/sauvegarde.log
sudo systemctl enable --now biolab-sauvegarde.timer
systemctl list-timers --all | grep biolab-sauvegarde
```

Ne pas recopier une sortie de `blkid` ou le fichier `/etc/biolab-backup.conf` contenant des valeurs specifiques a la VM dans Git ; le depot conserve uniquement le fichier `.example`.
