# Backupper

Scripts sécurisés pour sauvegarder vos volumes Docker avec Restic.

## Fonctionnalités

- Backup complet et sécurisé de volumes Docker avec Restic
- Installation automatique des dépendances
- Restauration facile
- Compatible avec différents backends (S3, sftp, local, etc.)
- Déduplication des données
- Chiffrement fort
- Politique de rétention flexible
- Notifications d'échec via webhooks (compatible Discord)
- Automatisation sécurisée via cron/systemd

## Prérequis

- Un système avec accès sudo ou droits d'installation
- Docker
- Internet pour l'installation des dépendances (si nécessaire)

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
# Modifiez les valeurs selon votre configuration, notamment:
# - RESTIC_PASSWORD 
# - RESTIC_REPOSITORY (s3:endpoint/bucket/path, sftp:user@host:/path, etc.)
# - Identifiants du backend si nécessaire (S3, etc.)
# - WEBHOOK_URL (optionnel, pour notifications Discord)
```

## Utilisation

### Backup manuel

```bash
./backup_volumes.sh
```

### Test des webhooks

Pour tester que vos webhook notifications fonctionnent correctement (notamment pour Discord) :

```bash
./test_notification.sh
```

Ce script vérifie :
- Que votre URL webhook est configurée
- L'envoi de messages normaux
- Le comportement en cas de message vide
- L'envoi de notifications d'erreur

### Restauration

```bash
# Lister les snapshots disponibles
RESTIC_PASSWORD="votre_mot_de_passe" restic -r "votre_repository" snapshots

# Restaurer un volume depuis un snapshot
./restore_volume.sh <nom_volume> <snapshot_id>
```

### Automatisation sécurisée

1. **Configurez votre cron**

```bash
crontab -e
```

2. **Ajoutez la tâche planifiée**

```
0 2 * * * /bin/bash -c 'BACKUP_ENV_FILE="$HOME/.backup_env" /chemin/vers/backup_volumes.sh 2>&1 | logger -t docker-backup'
```

3. **Vérifiez les logs**

```bash
grep docker-backup /var/log/syslog
```

## Notes de sécurité

- Le fichier .backup_env doit être protégé (chmod 600)
- Les dossiers temporaires sont automatiquement protégés (chmod 700)
- Les sauvegardes sont chiffrées avant de quitter votre serveur
- Aucun fichier n'est conservé localement (suppression immédiate après backup)

## Backends supportés par Restic

- Local (filesystem)
- S3 (AWS S3, Minio, tout stockage compatible S3)
- SFTP (serveur SSH)
- Rest Server (serveur REST dédié à Restic)
- Azure Blob Storage
- Google Cloud Storage
- Et bien d'autres...

## Licence

MIT