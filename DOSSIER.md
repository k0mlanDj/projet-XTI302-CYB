# Projet XTI302-CYB
# Durcissement d'un serveur Linux et preuve de conformité

**Environnement :** Laboratoire BioLab  
**Système d'exploitation :** Debian 13  
**Machine virtuelle :** Debian13-BioLab  
**Équipe responsable :**
- Komlan DJADOU
- Hugo BOUKRIA
- Malek BOUFAIED

**Date de réalisation :** novembre 2026

---

## 1. Présentation du projet

Ce projet consiste à déployer et sécuriser un serveur Linux Debian 13 destiné au laboratoire BioLab.

L'objectif est de protéger les comptes utilisateurs, contrôler les accès aux données, limiter les privilèges administratifs, sécuriser les connexions SSH, centraliser les journaux et mettre en place une stratégie de sauvegarde et de restauration.

Le travail a été réalisé collectivement par trois étudiants, avec une répartition des différents modules techniques et une intégration commune des composants dans une architecture cohérente.

Les principaux objectifs sont :

- appliquer le principe du moindre privilège ;
- contrôler les accès aux données selon les fonctions des utilisateurs ;
- sécuriser l'administration distante ;
- détecter les tentatives de connexion suspectes ;
- préserver les données et les journaux ;
- automatiser les sauvegardes ;
- rendre le déploiement reproductible ;
- vérifier la conformité au moyen de tests automatisés.

## 2. Organisation de l'équipe et répartition du travail

Le projet a été réalisé par Komlan DJADOU, Hugo BOUKRIA et Malek BOUFAIED. Chaque membre a pris en charge des composants techniques précis, puis les différentes contributions ont été intégrées dans le dépôt Git commun.

### 2.1 Komlan DJADOU — Comptes, accès et intégration

Komlan DJADOU a principalement travaillé sur la gestion des comptes, le contrôle des accès et l'intégration générale du projet.

Ses réalisations comprennent :

- développement et amélioration de `creer_comptes.sh` pour la création idempotente des utilisateurs et des groupes à partir de `comptes.csv` ;
- mise en place des permissions et ACL sur les répertoires de données BioLab ;
- configuration des clés publiques SSH et du durcissement OpenSSH ;
- configuration des droits sudo des administrateurs et du compte support ;
- intégration des configurations de sécurité dans le serveur Debian ;
- développement de `installer.sh` pour automatiser le déploiement ;
- développement de `verifier.sh` pour contrôler les exigences du sujet ;
- intégration des contributions de l'équipe, validation technique et gestion du dépôt Git.

### 2.2 Hugo BOUKRIA — Journaux et détection des incidents

Hugo BOUKRIA a pris en charge le module de journalisation et de protection contre les tentatives de connexion malveillantes.

Ses réalisations comprennent :

- développement de `analyse_logs.sh` pour analyser les événements SSH ;
- configuration de Fail2ban et de son filtre SSH adapté à l'environnement Debian ;
- configuration de la persistance des journaux avec systemd-journald ;
- définition des paramètres de détection et de bannissement des adresses IP ;
- réalisation des tests associés :
  - `test_analyse_logs.sh` ;
  - `test_fail2ban.sh` ;
  - `test_journald.sh` ;
- rédaction de la documentation technique relative aux journaux et à Fail2ban.

### 2.3 Malek BOUFAIED — Sauvegarde et restauration

Malek BOUFAIED a pris en charge le module de sauvegarde et de restauration, correspondant aux exigences B1 à B4 du sujet.

Ses réalisations comprennent :

- développement du système de sauvegarde de `/srv` et `/etc` avec rsync ;
- mise en place des sauvegardes incrémentales et de la conservation de sept versions ;
- automatisation des sauvegardes avec systemd ;
- développement du mécanisme de restauration ;
- contrôle des accès aux sauvegardes ;
- ajout des scripts, des fichiers de configuration et de la documentation associés ;
- préparation des tests de sauvegarde et de restauration.

Cette contribution a été intégrée dans le dépôt Git par la branche `feature/sauvegardes`, puis fusionnée dans `main` via la Pull Request n°1.

### 2.4 Travail collectif et intégration

Les trois contributions ont été réunies dans un même projet GitHub afin de centraliser les scripts, les configurations, les tests et la documentation.

L'intégration a notamment nécessité de vérifier la compatibilité entre les comptes, les groupes, les permissions, les services de sécurité et les mécanismes de sauvegarde.

Les tests ont ensuite été réalisés sur la machine virtuelle Debian 13.

## 3. Architecture technique

Le serveur est déployé dans une machine virtuelle Debian 13 administrée depuis un poste Ubuntu via SSH.

| Composant | Fonction |
|---|---|
| Debian 13 | Système d'exploitation |
| OpenSSH | Administration distante et accès SFTP |
| ACL | Gestion des droits d'accès aux données |
| sudo | Délégation contrôlée des privilèges |
| nftables | Filtrage du trafic réseau entrant |
| Fail2ban | Protection contre les tentatives répétées de connexion |
| systemd-journald | Collecte et conservation des journaux |
| rsync | Sauvegarde incrémentale |
| systemd timer | Planification des sauvegardes |
| unattended-upgrades | Gestion des mises à jour automatiques |

Le serveur dispose d'un disque système et d'un second disque virtuel dédié aux sauvegardes, identifié par son UUID et monté sur `/mnt/biolab-backups`.

## 4. Gestion des comptes et contrôle des accès

### 4.1 Comptes et groupes — C1

Le fichier `comptes.csv` constitue la source de référence pour la création des comptes.

Format utilisé :

`login;nom;groupe_principal;groupes_secondaires`

Les groupes fonctionnels sont :

- `admins` : administrateurs ;
- `support` : équipe de support ;
- `technique` : équipe technique ;
- `chercheurs` : chercheurs ;
- `doctorants` : doctorants ;
- `invite` : utilisateurs invités ;
- `acces_ssh` : utilisateurs autorisés à se connecter en SSH.

Le script `creer_comptes.sh` automatise la création des groupes et des utilisateurs. Il vérifie le fichier CSV et peut être exécuté plusieurs fois sans recréer les comptes existants.

### 4.2 Permissions et ACL — C2

Les trois espaces de données sont organisés sous `/srv`.

| Répertoire | Technique | Chercheurs | Doctorants | Invités |
|---|---|---|---|---|
| `/srv/donnees_brutes` | Lecture/écriture | Lecture | Lecture | Aucun accès |
| `/srv/analyses` | Aucun accès | Lecture/écriture | Lecture/écriture | Aucun accès |
| `/srv/publications` | Aucun accès | Lecture/écriture | Lecture | Lecture |

Les droits sont définis au moyen des ACL POSIX. Des ACL par défaut sont également configurées afin que les nouveaux fichiers et répertoires héritent des autorisations prévues.

### 4.3 Gestion des privilèges — C3

Les administrateurs appartenant au groupe `admins` disposent des droits sudo complets.

Le compte `support` est limité à l'exécution du script :

`/usr/local/sbin/analyse_logs.sh`

Cette autorisation est définie dans `/etc/sudoers.d/20-biolab-support`.

La configuration est contrôlée avec `visudo -cf /etc/sudoers`.

### 4.4 Protection des comptes — C4

Le compte root est verrouillé.

Les répertoires personnels des comptes du projet sont protégés avec des permissions `700`.

Les comptes invités utilisent le shell `/usr/sbin/nologin`. Leur accès est limité au transfert de fichiers par SFTP.

## 5. Sécurisation SSH et du système

### 5.1 Durcissement SSH — S1 à S5

La configuration est installée dans :

`/etc/ssh/sshd_config.d/00-biolab-auth.conf`

Les principales mesures sont :

- authentification par clé publique uniquement ;
- désactivation de l'authentification par mot de passe ;
- interdiction de la connexion directe de root ;
- restriction des connexions au groupe `acces_ssh` ;
- limitation à quatre tentatives d'authentification ;
- expiration des sessions inactives après quinze minutes ;
- accès des invités limité à `internal-sftp`.

Les clés publiques sont conservées dans `config/ssh-keys/`. Les clés privées ne doivent jamais être ajoutées au dépôt Git.

Un test réel de connexion SSH par clé publique a été effectué avec succès depuis le poste Ubuntu.

### 5.2 Journaux et protection contre les attaques — J1 à J4

**Fail2ban — J1**

Fail2ban surveille les événements SSH à partir du journal systemd. La configuration prévoit cinq tentatives échouées sur dix minutes, suivies d'un bannissement initial d'une heure. La durée peut augmenter en cas de récidive.

**Pare-feu nftables — J2**

Le pare-feu applique une politique entrante par défaut `drop`. Il autorise le trafic local, les connexions établies ou associées et les connexions TCP sur le port 22.

La table dédiée à BioLab est indépendante de celle utilisée par Fail2ban.

**Journald — J3**

La configuration impose la conservation persistante des journaux avec une limite d'utilisation de 300 Mo, une réserve minimale de 500 Mo et une durée maximale de conservation de six mois.

**Analyse des journaux — J4**

Le script `analyse_logs.sh` analyse les événements SSH, identifie les échecs par adresse IP et utilisateur et présente les connexions réussies. Le seuil d'alerte est configurable dans `/etc/biolab/analyse_logs.conf`.

## 6. Sauvegarde et restauration — B1 à B4

Ce module, développé par Malek BOUFAIED, utilise un second disque virtuel formaté en ext4 et identifié par son UUID.

Le script `sauvegarde.sh`, installé sous `/usr/local/sbin/biolab-sauvegarde`, réalise des sauvegardes de `/srv` et `/etc` avec rsync.

Les sauvegardes sont organisées en versions datées. L'utilisation de liens physiques avec `--link-dest` permet de ne pas recopier les fichiers inchangés entre les versions.

La politique de rétention est configurée pour conserver au minimum sept versions.

La planification est assurée par :
- `biolab-sauvegarde.service` ;
- `biolab-sauvegarde.timer`.

Le timer est programmé quotidiennement à 02 h 30.

Le script `restaurer_sauvegarde.sh`, installé sous `/usr/local/sbin/biolab-restaurer`, permet de récupérer un élément d'une version donnée dans un espace temporaire de restauration, sans écraser directement les répertoires système.

Un premier snapshot a été créé et un test de restauration du fichier `/etc/hostname` a été effectué avec vérification du contenu, des permissions et du propriétaire.

Le disque de sauvegarde n'est jamais formaté automatiquement par l'installateur.

## 7. Durcissement complémentaire — D1 à D3

**D1 — Mises à jour automatiques**

Le paquet `unattended-upgrades` est installé. Les mises à jour automatiques des listes de paquets et l'installation des mises à jour non supervisées sont configurées dans `/etc/apt/apt.conf.d/20auto-upgrades`.

**D2 — Services réseau**

L'inspection des sockets TCP en écoute confirme que SSH est le seul port TCP en écoute identifié. Les sockets UDP liés aux fonctions réseau du système sont distingués des services TCP accessibles.

**D3 — Permissions et SUID**

Une recherche des fichiers réguliers modifiables par tous, hors répertoires temporaires et pseudo-systèmes de fichiers, n'a retourné aucun résultat.

Les exécutables SUID présents sur Debian sont recensés afin d'identifier les programmes nécessitant une élévation contrôlée de privilèges. Ils ne sont pas supprimés arbitrairement.

## 8. Automatisation et reproductibilité

Le projet comporte les scripts principaux suivants :

| Script | Responsable principal | Rôle |
|---|---|---|
| `creer_comptes.sh` | Komlan DJADOU | Création des comptes, groupes, clés et permissions |
| `analyse_logs.sh` | Hugo BOUKRIA | Analyse des événements SSH |
| `sauvegarde.sh` | Malek BOUFAIED | Sauvegarde incrémentale |
| `restaurer_sauvegarde.sh` | Malek BOUFAIED | Restauration des données |
| `installer.sh` | Komlan DJADOU | Installation et déploiement des configurations |
| `verifier.sh` | Komlan DJADOU | Vérification automatisée des exigences |

Les fichiers de configuration, les tests et la documentation ont été intégrés au dépôt commun.

Le script `installer.sh` installe les dépendances, déploie les fichiers de configuration, configure les services et contrôle la validité de plusieurs éléments avant de terminer.

La configuration de sauvegarde existante est préservée. L'installateur ne partitionne et ne formate aucun disque.

Le script `verifier.sh` affiche un résultat PASS ou FAIL pour chaque contrôle et retourne un code de sortie nul lorsque tous les tests réussissent.

## 9. Résultats des vérifications

Le script `verifier.sh` a été exécuté sur la machine Debian 13.

**Résultat final : 29 tests réussis, aucun échec.**

Les vérifications couvrent les comptes, les groupes, les ACL, les privilèges sudo, le verrouillage de root, les paramètres SSH, Fail2ban, nftables, journald, les sauvegardes, le timer systemd, les mises à jour automatiques, les ports TCP et les permissions des fichiers.

Ces résultats démontrent la réussite des contrôles automatisés. Ils ne remplacent pas les essais fonctionnels et les vérifications après redémarrage.

## 10. Limites et améliorations possibles

Certaines vérifications nécessitent une observation sur une période plus longue :

- exécuter plusieurs sauvegardes afin de confirmer le comportement incrémental entre versions ;
- vérifier la rétention effective après la création de plus de sept versions ;
- contrôler la persistance des journaux après un redémarrage ;
- vérifier périodiquement la restauration de différents fichiers ;
- conserver les preuves des tests d'accès autorisés et refusés pour chaque catégorie d'utilisateur.

La présence d'une configuration ou d'un service actif ne constitue pas, à elle seule, une preuve de fonctionnement dans tous les scénarios.

## 11. Procédure de restauration

La restauration d'un fichier doit être effectuée par un administrateur.

Commande générale :

`sudo /usr/local/sbin/biolab-restaurer VERSION srv/chemin/relatif`

ou :

`sudo /usr/local/sbin/biolab-restaurer VERSION etc/chemin/relatif`

Exemple :

`sudo /usr/local/sbin/biolab-restaurer 20261105_121100_470731607 etc/hostname`

La version doit correspondre à un snapshot valide contenant le marqueur `.complete`.

Le fichier restauré est placé dans `/var/tmp/biolab-restauration` pour permettre sa vérification avant toute remise en place.

## Conclusion

Le projet BioLab a été réalisé collectivement par Komlan DJADOU, Hugo BOUKRIA et Malek BOUFAIED.

Les trois membres ont contribué à des domaines complémentaires : gestion des comptes et intégration de la sécurité, journalisation et détection des incidents, sauvegarde et restauration.

L'ensemble des contributions a permis de mettre en place une architecture Debian 13 durcie, documentée et vérifiable. L'automatisation et les tests facilitent la reproduction du déploiement et le contrôle des principales exigences du sujet.

Le projet constitue ainsi une mise en pratique collective des principes d'administration système, de sécurité Linux, de gestion des accès, de journalisation et de protection des données.
