# Backupper

Scripts sécurisés pour sauvegarder vos volumes Docker sur un stockage S3 compatible avec chiffrement GPG.

## Fonctionnalités

- Backup complet de volumes Docker
- Chiffrement fort avec GPG
- Upload vers stockage S3 compatible (Minio, AWS S3, etc.)
- Restauration facile
- Compression (gzip ou zstd en option)
- Checksums pour vérifier l'intégrité des données
- Notifications de succès/échec
- Automatisation sécurisée via cron/systemd

## Prérequis

- Docker
- gpg
- aws-cli
- bash

## Installation

```bash
git clone https://github.com/rubynouille/backupper.git
cd backupper
chmod +x *.sh
```

## Configuration sécurisée

1. **Créez votre fichier d'environnement**

```bash
cp .backup_env.example ~/.backup_env
chmod 600 ~/.backup_env  # IMPORTANT: permissions restreintes
```

2. **Éditez votre fichier d'environnement**

```bash
nano ~/.backup_env
# Modifiez les valeurs selon votre configuration
```

## Utilisation

### Backup manuel

```bash
./backup_volumes_gpg_s3.sh
```

### Restauration

```bash
./restore_volume_from_s3.sh <nom_volume> <timestamp> <fichier_backup.gpg>
```

### Automatisation sécurisée

1. **Configurez votre cron**

```bash
crontab -e
```

2. **Ajoutez la tâche planifiée**

```
0 2 * * * /bin/bash -c 'BACKUP_ENV_FILE="$HOME/.backup_env" /chemin/vers/backup_volumes_gpg_s3.sh 2>&1 | logger -t docker-backup'
```

3. **Vérifiez les logs**

```bash
grep docker-backup /var/log/syslog
```

## Notes de sécurité

- Le fichier .backup_env doit être protégé (chmod 600)
- Les dossiers de backup sont automatiquement protégés (chmod 700)
- L'automatisation est sécurisée si vos variables d'environnement sont correctement protégées
- Les sauvegardes sont chiffrées avec GPG avant de quitter votre serveur

## Licence

MIT