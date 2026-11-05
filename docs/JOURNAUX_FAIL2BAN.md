# J1, J3, J4 — Fail2ban, persistance journald, analyse des journaux SSH

Projet XTI302-CYB — Laboratoire BioLab
Responsable : Hugo Boukria — branche `feature/journaux-fail2ban`

Ce document décrit l'installation, le fonctionnement et les tests des exigences
J1 (protection contre la force brute), J3 (persistance des journaux) et J4
(script d'analyse des journaux SSH). Il s'adresse à l'intégrateur
(`installer.sh`, `verifier.sh`) et aux responsables de J2 (pare-feu) et de C3
(durcissement SSH).

---

## 1. Fichiers livrés

| Fichier du dépôt | Destination sur le serveur | Propriétaire / droits |
|---|---|---|
| `analyse_logs.sh` | `/usr/local/sbin/analyse_logs.sh` | `root:root 0755` |
| `config/analyse_logs/analyse_logs.conf` | `/etc/biolab/analyse_logs.conf` | `root:root 0644` |
| `config/fail2ban/jail.local` | `/etc/fail2ban/jail.local` | `root:root 0644` |
| `config/fail2ban/filter.d/sshd.local` | `/etc/fail2ban/filter.d/sshd.local` | `root:root 0644` |
| `config/journald/10-biolab-persistance.conf` | `/etc/systemd/journald.conf.d/10-biolab-persistance.conf` | `root:root 0644` |
| `tests/test_analyse_logs.sh` | (reste dans le dépôt) | exécuté par un utilisateur non root |
| `tests/test_fail2ban.sh` | (reste dans le dépôt) | exécuté avec sudo |
| `tests/test_journald.sh` | (reste dans le dépôt) | exécuté avec sudo |

Aucun fichier existant du dépôt n'est modifié en dehors de `analyse_logs.sh`
(vide jusqu'ici). `creer_comptes.sh`, `installer.sh`, `verifier.sh`, sudoers et
nftables ne sont pas touchés.

---

## 2. État initial constaté (archive du 04/11/2026)

- Debian 13.7, noyau 6.12.113, OpenSSH 10.0p1, systemd 257.13.
- Les lignes de connexion SSH sont écrites par `sshd-session[PID]` (et non
  `sshd[PID]`), dans l'unité `ssh.service`.
- rsyslog n'est pas installé : pas de `/var/log/auth.log` attendu.
- fail2ban absent ; nftables installé (1.1.3) mais `nftables.service`
  désactivé et inactif.
- journald actif, 24 Mo de journaux. La persistance **n'est pas démontrée** par
  l'archive : ni le contenu de `/var/log/journal`, ni `journalctl --list-boots`
  n'y figurent. Elle est rendue explicite par J3 et prouvée par
  `tests/test_journald.sh`.
- `/var` est une partition dédiée de 2,1 Go (1,6 Go libres).
- Toutes les connexions d'administration relevées viennent de `192.168.122.1`
  (hôte libvirt, passerelle du réseau NAT).
- `analyse_logs.sh` appartient à `root:root` (0750) dans le dépôt de
  `biolab-admin` : avant de le remplacer, rendre le fichier à son propriétaire
  (`sudo chown biolab-admin:biolab-admin analyse_logs.sh`), sinon `git` ne
  pourra pas l'écrire.

---

## 3. Ambiguïtés relevées et décisions prises

| # | Point | Décision |
|---|---|---|
| A1 | Le sujet PDF du projet n'était pas disponible lors du développement. Références utilisées : la fiche de mission, l'archive d'état des lieux et le cours XTI302-CYB CM4 (« Journalisation et durcissement »). | À relire contre le sujet avant la fusion. |
| A2 | Le CM4 esquisse `analyse_logs.sh [-f fichier] [-s seuil]`, alors que la mission impose une interface fermée pour `support` via sudo. | **En root (sudo) : aucun argument accepté**, réglages dans `/etc/biolab/analyse_logs.conf`. **Hors root** : `-f FICHIER [-s SEUIL]` permis, car le script lit alors le fichier avec les droits de l'appelant (aucune élévation). |
| A3 | « Seuil dépassé » (mission) contre « exit 1 si une IP **atteint** le seuil » (CM4). | Alerte dès qu'une adresse IP **atteint** le seuil (≥). Avec `SEUIL_ECHECS_IP=5`, cohérent avec `maxretry = 5` de fail2ban. |
| A4 | Unité du seuil : total ou par adresse IP. | Par adresse IP (CM4 : « une IP atteint le seuil »). |
| A5 | La mission demande `jail.local` ; le CM4 utilise `jail.d/sshd-tp.conf`. | `jail.local`, lu après `jail.d/*.conf` : il l'emporte donc sur `defaults-debian.conf`. |
| A6 | Exempter `192.168.122.1` empêche de tester un bannissement réel depuis l'hôte, et dans la topologie NAT libvirt toute connexion venant de l'hôte porte cette adresse. | Adresse exemptée (exigence « ne pas se bannir ») ; test réel depuis un espace de noms réseau isolé (`10.203.0.2`) qui n'est pas exempté. Voir § 4.5. |
| A7 | Les répertoires vides `config/fail2ban/`, `config/sudoers/`, `config/nftables/` annoncés n'apparaissent pas dans l'archive (Git ne suit pas les répertoires vides). | `config/fail2ban/` est créé par ce livrable. |
| A8 | Code « C3 » : supposé désigner le durcissement SSH (`PasswordAuthentication no`). | À confirmer avec l'équipe. |

---

## 4. J1 — Fail2ban

### 4.1 Principe

fail2ban lit le journal systemd, reconnaît les échecs SSH (filtre `sshd`),
compte les échecs par adresse IP (jail `sshd`) et bannit l'adresse via
nftables (action `nftables-multiport`).

### 4.2 Choix techniques

- **Backend `systemd`** : Debian 13 n'a pas de `/var/log/auth.log`. Nécessite
  le paquet `python3-systemd`.
- **`journalmatch = _SYSTEMD_UNIT=ssh.service`** : sous Debian, l'unité
  s'appelle `ssh.service` (le filtre amont vise `sshd.service`). Le champ
  `_SYSTEMD_UNIT` est attribué par journald d'après le cgroup du processus : un
  utilisateur local ne peut pas le falsifier, contrairement à `_COMM` ou à
  l'identifiant syslog (`logger -t sshd-session ...`). Cela évite qu'un
  utilisateur local fasse bannir une adresse arbitraire en injectant de fausses
  lignes.
- **`filter.d/sshd.local`** : élargit le nom de démon à
  `sshd(?:-session|-auth)?` (OpenSSH ≥ 9.8). Sans cela, selon la version du
  filtre, aucune ligne `sshd-session[...]` ne serait reconnue. Le test
  fail2ban-regex (§ 4.6) le vérifie.
- **`mode = normal`** : reconnaît `Failed password`, `Invalid user`, comptes
  hors `AllowGroups`, dépassement de `MaxAuthTries`, sans les motifs
  « agressifs » (échanges de clés interrompus, etc.) qui augmentent les faux
  positifs. Après C3, `mode = aggressive` pourra être réévalué.

### 4.3 Valeurs retenues

| Paramètre | Valeur | Justification |
|---|---|---|
| `maxretry` | 5 | Une personne qui se trompe tape 1 à 3 mots de passe faux ; un robot en essaie des centaines. Remarque : avec `MaxAuthTries 4` (sshd), une seule connexion peut produire jusqu'à 4 échecs ; 5 laisse donc une marge pour une seconde tentative humaine. |
| `findtime` | 10 min | Fenêtre où les échecs sont cumulés : suffisante pour un robot rapide, assez courte pour oublier des erreurs espacées d'un utilisateur. |
| `bantime` | 1 h | Rend une attaque par dictionnaire inexploitable (au plus 5 essais par heure et par adresse) sans bloquer durablement un utilisateur légitime. |
| `bantime.increment` / `bantime.maxtime` | oui / 24 h | Une adresse récidiviste voit sa durée doubler à chaque bannissement, jusqu'à 24 h. |
| `ignoreip` | `127.0.0.1/8 ::1 192.168.122.1` | Boucle locale et poste d'administration (voir A6). |
| `banaction` | `nftables-multiport` | Architecture pare-feu du projet : nftables (J2). |

### 4.4 Interface avec J2 (nftables)

- L'action crée et gère **sa propre table** `table inet f2b-table` (chaîne
  attachée au hook `input` avec une priorité de -1). Elle n'utilise ni
  `/etc/nftables.conf`, ni `nftables.service` : elle fonctionne **que le
  service nftables soit actif ou non** (seuls la commande `nft` et le noyau sont
  requis). C'est le cas aujourd'hui (service inactif).
- Un paquet rejeté dans `f2b-table` reste rejeté, quelles que soient les règles
  `accept` de la table de J2 : les deux politiques s'additionnent.
- **Point de vigilance pour J2** : si `/etc/nftables.conf` commence par
  `flush ruleset`, un `systemctl restart nftables` supprime aussi
  `f2b-table` et les bannissements en cours. Deux solutions, à choisir avec J2 :
  1. ne vider que la table du projet (`table inet filtre` +
     `delete table inet filtre` en tête du fichier) au lieu de `flush ruleset` ;
  2. vérifier que `fail2ban.service` est bien `PartOf=nftables.service`
     (cas de l'unité fournie par fail2ban ; affiché par
     `tests/test_fail2ban.sh`) : il est alors redémarré avec nftables et
     restaure ses bannissements depuis sa base.
- J2 doit continuer à autoriser le port 22 : fail2ban ne fait que retirer des
  adresses précises.

### 4.5 Ne pas se bannir

- `192.168.122.1` figure dans `ignoreip`.
- Garder une session SSH ouverte pendant les tests, et la console libvirt
  (virt-manager) comme accès de secours.
- Les tests de bannissement n'utilisent jamais l'adresse d'administration :
  adresse de documentation `192.0.2.66` (bannissement manuel) et espace de noms
  réseau `10.203.0.2` (bannissement réel).

### 4.6 Vérification et exploitation

```bash
sudo systemctl status fail2ban
sudo fail2ban-client status sshd                # échecs vus, adresses bannies
sudo fail2ban-client get sshd maxretry          # 5 si jail.local est pris en compte
sudo fail2ban-client get sshd findtime          # 600
sudo fail2ban-client get sshd bantime           # 3600
sudo fail2ban-client get sshd journalmatch
sudo nft list table inet f2b-table              # adresses bannies côté pare-feu
sudo journalctl -u fail2ban --since "1 hour ago"
```

Débannir une adresse :

```bash
sudo fail2ban-client set sshd unbanip 203.0.113.45
```

---

## 5. J3 — Persistance de journald

### 5.1 Vérifier l'état réel (avant configuration)

L'absence de `Storage=` dans un fichier ne signifie pas « non persistant » :
la valeur par défaut est `auto`, qui écrit sur disque **si**
`/var/log/journal` existe. Il faut donc regarder :

```bash
systemd-analyze cat-config systemd/journald.conf | grep -E '^[[:space:]]*Storage='
ls -ld /var/log/journal /var/log/journal/$(cat /etc/machine-id)
ls -l /run/log/journal 2>/dev/null
journalctl --list-boots
journalctl --disk-usage
```

- `/var/log/journal/<machine-id>/system.journal` présent et plusieurs
  démarrages listés : persistant.
- Seul `/run/log/journal` présent, un seul démarrage listé : volatil.

### 5.2 Configuration

Fichier complémentaire `/etc/systemd/journald.conf.d/10-biolab-persistance.conf`
(emplacement prévu par systemd sous Debian 13 : le fichier fourni par le
paquet n'est pas modifié) :

| Directive | Valeur | Justification |
|---|---|---|
| `Storage` | `persistent` | Écriture sur disque explicite, création du répertoire si besoin. |
| `Compress` | `yes` | Valeur par défaut, explicitée. |
| `SystemMaxUse` | `300M` | ~14 % de `/var` (2,1 Go) ; 24 Mo occupés aujourd'hui, donc plusieurs mois de marge. |
| `SystemKeepFree` | `500M` | Les journaux ne peuvent pas saturer `/var` (apt, sauvegardes). |
| `SystemMaxFileSize` | `30M` | Rotation par tranches : la suppression des plus anciennes entrées libère peu à la fois. |
| `MaxRetentionSec` | `6month` | Conservation de référence des traces d'accès ; la limite de taille l'emporte si elle est atteinte avant. |
| `RuntimeMaxUse` | `50M` | Journal volatil (avant le montage de `/var`). |

Les limites étant supérieures à l'occupation actuelle, la prise en compte ne
supprime aucune entrée existante. Aucune commande `--vacuum` n'est utilisée.

### 5.3 Permissions attendues

| Chemin | Propriétaire | Droits |
|---|---|---|
| `/var/log/journal` | `root:systemd-journal` | `2755` (+ ACL `adm` posées par systemd-tmpfiles) |
| `/var/log/journal/<machine-id>` | `root:systemd-journal` | `2755` |
| `*.journal` | `root:systemd-journal` | `0640` |

Ces droits sont appliqués par `systemd-tmpfiles` (règles fournies par
systemd), pas fixés à la main.

### 5.4 Prouver la persistance

1. `sudo bash tests/test_journald.sh` : écrit un événement de test et le relit
   **directement depuis `/var/log/journal`** (`journalctl -D`), ce qui prouve
   qu'il est sur disque. (Redémarrer seulement journald ne prouve rien :
   `/run` survit à ce redémarrage.)
2. `sudo reboot`
3. `sudo bash tests/test_journald.sh --apres-redemarrage` : au moins deux
   démarrages listés, et l'événement de test du démarrage précédent est
   relu avec `journalctl -b -1`.

---

## 6. J4 — `analyse_logs.sh`

### 6.1 Utilisation

```bash
sudo /usr/local/sbin/analyse_logs.sh            # mode nominal (support via sudo)
echo $?                                         # 0 = OK, 1 = seuil atteint

analyse_logs.sh -f export_ssh.log -s 3          # hors ligne, utilisateur non root
analyse_logs.sh -h
```

En root (y compris via sudo), **tout argument est refusé** (code 2), sauf
`-h`. Le seuil ne se change qu'en éditant `/etc/biolab/analyse_logs.conf`,
qui appartient à root.

### 6.2 Configuration `/etc/biolab/analyse_logs.conf`

Format `CLE=valeur`, une directive par ligne, lettres et chiffres uniquement,
commentaires `#`. Le fichier est **lu et validé ligne à ligne, jamais
exécuté** (ni `source`, ni `eval`). En root, il doit appartenir à root et ne
pas être modifiable par le groupe ou les autres, sinon le script refuse de
s'exécuter (code 5). Fichier absent : valeurs par défaut et avertissement.

| Clé | Défaut | Valeurs |
|---|---|---|
| `SEUIL_ECHECS_IP` | `5` | entier 1 à 100000 ; alerte si une IP l'atteint |
| `PERIODE` | `24h` | `Nh`, `Nd` (N de 1 à 9999) ou `tout` |
| `SOURCE` | `auto` | `auto`, `journald`, `authlog` |
| `NB_LIGNES_MAX` | `10` | entier 1 à 100 (lignes par classement) |

### 6.3 Sources de journaux

- `journald` : `journalctl -u ssh.service --since ... -o short-iso`. Le
  filtrage par unité (et non par `-t sshd`) écarte les fausses lignes qu'un
  utilisateur local pourrait injecter avec `logger`.
- `authlog` : `/var/log/auth.log` (fichier courant uniquement), si rsyslog
  est installé. Chemin fixe, non modifiable.
- `auto` : journald ; repli sur `auth.log` seulement si journalctl échoue ou
  ne renvoie aucune ligne SSH sur la période. Les deux sources ne sont **jamais
  additionnées** (rsyslog recopie journald : on compterait tout deux fois).

### 6.4 Règles de comptage

Une connexion = un PID `sshd-session` + une adresse IP (le PID relie les
lignes d'une même connexion, cf. CM4).

- Chaque ligne `Failed <méthode> for ...` compte pour un échec.
- Une connexion sans `Failed` ni `Accepted`, mais refusée avant
  authentification (`Invalid user`, compte hors `AllowGroups`,
  `Connection closed by authenticating|invalid user ... [preauth]`,
  `maximum authentication attempts exceeded`) compte pour **un** échec. C'est
  la forme que prennent les échecs après durcissement (clé seule, C3).
- Les lignes PAM et les lignes redondantes d'une même connexion ne sont pas
  recomptées (une tentative produit environ cinq lignes).
- Les balayages sans nom d'utilisateur (`Connection closed by IP port N
  [preauth]`) ne sont pas comptés.

### 6.5 Rapport

Sections : en-tête (machine, date, source, période, seuil), 1. échecs,
2. adresses IP sources (avec mention « SEUIL ATTEINT »), 3. comptes ciblés
(« inexistant ou non autorisé »), 4. connexions réussies (par compte, adresse
et méthode, puis les dernières), remarques, 5. bilan avec le code de retour.

Extrait réel (jeu de test `attaque.log`, `-s 5`) :

```text
--- 2. Adresses IP sources des échecs (10 premières) ---
  ÉCHECS  ADRESSE IP                              ÉTAT
       6  203.0.113.45                            SEUIL ATTEINT
       4  198.51.100.23
       1  192.0.2.7
...
--- 5. Bilan synthétique ---
Échecs d'authentification   : 15 (7 adresse(s) IP, 11 compte(s))
Connexions réussies         : 3 (dont 1 par mot de passe)
Seuil par adresse IP        : 5
Résultat                    : ALERTE - 1 adresse(s) IP atteignent le seuil : 203.0.113.45
Code de retour              : 1
```

### 6.6 Codes de retour

| Code | Signification |
|---|---|
| 0 | Analyse terminée, aucune IP n'atteint le seuil (y compris journal vide) |
| 1 | Alerte : au moins une IP atteint le seuil |
| 2 | Argument invalide ou refusé |
| 3 | Dépendance manquante |
| 4 | Privilèges insuffisants (lecture du journal système sans root) |
| 5 | Configuration invalide ou non sécurisée |
| 6 | Source de journaux indisponible |
| 70 | Erreur interne inattendue |

### 6.7 Sécurité

- `set -Eeuo pipefail` + `inherit_errexit` ; piège `ERR` qui transforme toute
  erreur imprévue en code 70 ; aucun `head` en fin de tube (évite les arrêts
  par SIGPIPE avec `pipefail`).
- En root : `PATH` fixé, `umask 077`, `LC_ALL=C`, interface fermée, chemins
  de configuration et de journaux fixes.
- Lecture seule : seul un répertoire temporaire privé (`mktemp -d`) est créé,
  puis supprimé à la sortie.
- Noms d'utilisateurs (contrôlés par l'attaquant) réduits à
  `[A-Za-z0-9._@+-]` et 32 caractères : pas d'injection de séquences
  d'échappement dans le terminal de l'administrateur.
- Les lignes brutes ne sont jamais réaffichées : ni empreinte de clé, ni
  message PAM. Limite connue : si un utilisateur tape son mot de passe à la
  place de son identifiant, ce texte apparaît comme « compte ciblé ». C'est
  inhérent aux journaux sshd ; le rapport est réservé à root/support.
- awk POSIX uniquement (compatible `mawk`, l'awk par défaut de Debian).

### 6.8 Règle sudoers proposée (à valider par l'intégrateur)

Non installée par ce livrable. Proposition pour `config/sudoers/` :

```text
# support peut lancer l'analyse, sans aucun argument ("" = aucun argument permis)
support ALL=(root) /usr/local/sbin/analyse_logs.sh ""
```

À valider avec `visudo -cf <fichier>` et à installer en `root:root 0440`.

---

## 7. Interface avec `installer.sh` et `verifier.sh`

Ces scripts ne sont pas modifiés. Fonctions proposées à l'intégrateur (même
conventions que `creer_comptes.sh` : `log`, `install`, idempotence) :

```bash
# J1 - fail2ban
installer_fail2ban() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban python3-systemd nftables
    install -o root -g root -m 644 "$SCRIPT_DIR/config/fail2ban/jail.local" /etc/fail2ban/jail.local
    install -o root -g root -m 644 "$SCRIPT_DIR/config/fail2ban/filter.d/sshd.local" \
        /etc/fail2ban/filter.d/sshd.local
    fail2ban-client -t
    systemctl enable fail2ban
    systemctl restart fail2ban
    log "fail2ban installé et jail sshd active."
}

# J3 - journald persistant (ne supprime aucun journal existant)
configurer_journald() {
    install -d -o root -g root -m 755 /etc/systemd/journald.conf.d
    install -o root -g root -m 644 "$SCRIPT_DIR/config/journald/10-biolab-persistance.conf" \
        /etc/systemd/journald.conf.d/10-biolab-persistance.conf
    install -d -o root -g systemd-journal -m 2755 /var/log/journal
    systemd-tmpfiles --create --prefix /var/log/journal
    systemctl restart systemd-journald
    journalctl --flush
    log "journald persistant configuré."
}

# J4 - script d'analyse
installer_analyse_logs() {
    install -o root -g root -m 755 "$SCRIPT_DIR/analyse_logs.sh" /usr/local/sbin/analyse_logs.sh
    install -d -o root -g root -m 755 /etc/biolab
    install -o root -g root -m 644 "$SCRIPT_DIR/config/analyse_logs/analyse_logs.conf" \
        /etc/biolab/analyse_logs.conf
    log "analyse_logs.sh installé dans /usr/local/sbin."
}
```

Ordre conseillé : J3 (journald) avant J1 (fail2ban lit le journal), J2
(nftables) avant ou après J1 selon le choix fait au § 4.4.

Pour `verifier.sh` : appeler `tests/test_fail2ban.sh` et
`tests/test_journald.sh` (code 0 = conforme), et
`sudo /usr/local/sbin/analyse_logs.sh` (code 0 ou 1 = script fonctionnel,
autre code = défaut).

---

## 8. Tests

### 8.1 Commandes

```bash
# J4 : utilisateur non root, n'importe quelle machine avec bash, awk, coreutils
bash tests/test_analyse_logs.sh

# J4 : sur la VM, après installation
sudo /usr/local/sbin/analyse_logs.sh; echo "code=$?"
sudo /usr/local/sbin/analyse_logs.sh -s 1; echo "code=$?"   # attendu : 2 (argument refusé en root)

# J1 : sur la VM, après installation
sudo bash tests/test_fail2ban.sh
sudo bash tests/test_fail2ban.sh --bannissement-reel

# J3 : sur la VM, après installation
sudo bash tests/test_journald.sh --redemarrer-journald
sudo reboot
sudo bash tests/test_journald.sh --apres-redemarrage
```

### 8.2 Couverture

| Exigence | Test |
|---|---|
| J4 sans échec / plusieurs échecs / plusieurs IP / plusieurs comptes / réussites | `test_analyse_logs.sh` cas 1 à 5 |
| J4 seuil non atteint / atteint / dépassé | cas 6 et 7 |
| J4 journal vide / indisponible | cas 8 (et code 6 en cas d'échec de journalctl) |
| J4 dépendance absente | cas 9 (awk retiré du PATH) |
| J4 interface et privilèges | cas 10 |
| J4 assainissement de l'affichage | cas 11 |
| J4 configuration (validation, pas d'exécution) | cas 12 |
| J1 installation, service, jail, paramètres effectifs | `test_fail2ban.sh` sections 1 à 4 |
| J1 détection des échecs `sshd-session` | section 5 (fail2ban-regex) |
| J1 bannissement / débannissement | sections 6 et 7 |
| J3 configuration, permissions, écriture, relecture sur disque | `test_journald.sh` sections 1 à 3 |
| J3 redémarrage de journald / de la VM | options `--redemarrer-journald`, `--apres-redemarrage` |

### 8.3 Résultats réellement obtenus

Exécutés le 05/11/2026 sur le poste de développement (Windows 11, Git Bash :
GNU bash 5.2.37, GNU awk 5.3.2, coreutils), **pas sur la VM Debian 13** :

- `bash -n` : OK pour `analyse_logs.sh` et les trois scripts de test.
- Aucune fin de ligne CRLF dans le livrable.
- `tests/test_analyse_logs.sh` : **49 tests réussis, 0 échec**, avec
  `gawk` et avec `gawk --posix` (approximation de la compatibilité mawk).

Non exécutés (nécessitent la VM, fail2ban et systemd) :

- `tests/test_fail2ban.sh` et `tests/test_journald.sh` : seule leur syntaxe a
  été vérifiée.
- `analyse_logs.sh` en mode journald (root, `journalctl`) et sous `mawk`.
- Validation des fichiers de configuration par `fail2ban-client -t` et
  `systemd-analyze cat-config`.

Ces exigences ne sont donc **pas encore validées** : il reste à lancer les
commandes du § 8.1 sur la VM et à reporter leurs sorties dans `DOSSIER.md`.

---

## 9. Limites et dépendances

- **J2** : interaction `flush ruleset` / `f2b-table` (§ 4.4). Si J2 adopte
  une politique `drop` en entrée, le test `--bannissement-reel` signale que
  l'interface de test est bloquée (test non concluant, pas un échec de J1).
- **C3** : tant que `PasswordAuthentication yes` reste effectif, la force
  brute par mot de passe est possible ; fail2ban la ralentit mais ne la rend
  pas impossible. Après C3, les échecs prennent surtout la forme
  `Connection closed by authenticating user ... [preauth]`, comptée par J4 ;
  côté fail2ban, réévaluer `mode = aggressive`.
- **Installateur** : installe les paquets (`fail2ban`, `python3-systemd`),
  copie les fichiers (§ 7), crée `/etc/biolab`, et propose la règle sudoers
  (§ 6.8). `installer.sh` est vide aujourd'hui.
- **fail2ban** ne protège ni d'une clé volée, ni d'un attaquant qui change
  d'adresse ; l'exemption de `192.168.122.1` exempte aussi tout trafic que
  l'hôte relaierait.
- **auth.log** : seul le fichier courant est lu (pas les archives `.1`,
  `.gz`). En mode `-f`, la période n'est pas appliquée.
- Les règles fail2ban (`sshd.local`, `journalmatch`) reposent sur le
  comportement documenté de fail2ban 1.1 ; elles sont à confirmer par
  `fail2ban-regex` et `fail2ban-client get sshd journalmatch` sur la VM.
