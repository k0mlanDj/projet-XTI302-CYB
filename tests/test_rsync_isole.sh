#!/usr/bin/env bash
# Test local sans partitions, formatage ni modification de /srv ou /etc.
# Teste la mecanique rsync --link-dest, les metadonnees et une restauration.
set -Eeuo pipefail
umask 077
for tool in rsync stat cmp mktemp; do
    command -v "$tool" >/dev/null || { echo "MANQUANT : $tool" >&2; exit 1; }
done
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/source/srv/analyses" "$TMP/backup/versions/v1/srv" "$TMP/backup/versions/v2/srv" "$TMP/backup/versions/v3/srv" "$TMP/restore"
printf 'VERSION_INITIALE\n' > "$TMP/source/srv/analyses/echantillon.txt"
chmod 0640 "$TMP/source/srv/analyses/echantillon.txt"
ln -s echantillon.txt "$TMP/source/srv/analyses/lien-sym.txt"
ln "$TMP/source/srv/analyses/echantillon.txt" "$TMP/source/srv/analyses/lien-physique.txt"
XATTR_TEST='NON_TESTE'
if command -v python3 >/dev/null; then
  if python3 - "$TMP/source/srv/analyses/echantillon.txt" <<'PY'
import os, sys
try:
    os.setxattr(sys.argv[1], b'user.biolab', b'valeur-xattr')
except OSError:
    sys.exit(1)
PY
  then XATTR_TEST='PRESENT'; fi
fi
rsync -aAXH --numeric-ids "$TMP/source/srv/" "$TMP/backup/versions/v1/srv/"
rsync -aAXH --numeric-ids --link-dest="$TMP/backup/versions/v1/srv" \
    "$TMP/source/srv/" "$TMP/backup/versions/v2/srv/"
V1="$TMP/backup/versions/v1/srv/analyses/echantillon.txt"
V2="$TMP/backup/versions/v2/srv/analyses/echantillon.txt"
V3="$TMP/backup/versions/v3/srv/analyses/echantillon.txt"
[[ "$(stat -c %i "$V1")" == "$(stat -c %i "$V2")" ]] || { echo 'ECHEC : inodes differents pour fichier inchange'; exit 1; }
echo 'OK : lien physique (inode commun pour version inchangee).'
[[ "$(stat -c %a "$V1")" == '640' ]] || { echo 'ECHEC permissions'; exit 1; }
[[ -L "$TMP/backup/versions/v2/srv/analyses/lien-sym.txt" ]] || { echo 'ECHEC lien symbolique'; exit 1; }
[[ "$(stat -c %i "$TMP/backup/versions/v1/srv/analyses/lien-physique.txt")" == "$(stat -c %i "$V1")" ]] || { echo 'ECHEC hardlink source'; exit 1; }
echo 'OK : mode 0640, lien symbolique et liens physiques preserves.'
if [[ "$XATTR_TEST" == PRESENT ]]; then
  python3 - "$V1" <<'PY'
import os,sys
assert os.getxattr(sys.argv[1],b'user.biolab') == b'valeur-xattr'
PY
  echo 'OK : attribut etendu user.biolab preserve.'
else
  echo 'NON TESTE : creation de xattr refusee dans cet environnement.'
fi
printf 'VERSION_MODIFIEE\n' > "$TMP/source/srv/analyses/echantillon.txt"
rsync -aAXH --numeric-ids --link-dest="$TMP/backup/versions/v2/srv" \
    "$TMP/source/srv/" "$TMP/backup/versions/v3/srv/"
[[ "$(stat -c %i "$V2")" != "$(stat -c %i "$V3")" ]] || { echo 'ECHEC : inode modifie partage'; exit 1; }
[[ "$(cat "$V2")" == VERSION_INITIALE && "$(cat "$V3")" == VERSION_MODIFIEE ]] || { echo 'ECHEC historique'; exit 1; }
echo 'OK : fichier modifie independant, historique v2 intact.'
rsync -aAXH --numeric-ids "$TMP/backup/versions/v2/srv/analyses/" "$TMP/restore/"
cmp "$V2" "$TMP/restore/echantillon.txt"
[[ "$(stat -c %a "$TMP/restore/echantillon.txt")" == 640 ]] || { echo 'ECHEC restauration des permissions'; exit 1; }
echo 'OK : restauration isolee et contenu identique.'
if command -v getfacl >/dev/null && command -v setfacl >/dev/null; then
  echo 'INFO : outils ACL presents ; test ACL explicite a realiser sur VM avec le scenario documente.'
else
  echo 'NON TESTE : ACL nommees (outils setfacl/getfacl absents localement).'
fi
printf 'RESULTAT LOCAL : TESTS D INCREMENTATION ET DE RESTAURATION REUSSIS.\n'
