# Outils d'exploitation pour un VPS en conteneurs LXC

Scripts que j'utilise pour exploiter mon VPS de production : chaque service tourne dans son propre conteneur LXC, derrière un reverse proxy Nginx qui gère le TLS.

```
Internet ──> Nginx (reverse proxy, TLS Let's Encrypt, fail2ban, en-têtes de sécurité)
                │
                ├── conteneur site WordPress ──> conteneur MariaDB dédié
                ├── conteneur blog Dotclear  ──> conteneur MariaDB dédié
                ├── conteneur site statique
                ├── conteneurs applicatifs Alpine (authentification, supervision…)
                └── conteneur rsyslog central (journaux de toutes les machines)
```

## Scripts

### `lxc-expose`
Publie le service d'un conteneur en HTTPS sur un sous-domaine, en une commande :

```bash
lxc-expose monapp 10.0.3.105:8080 [--auth] [--ws]
```

- génère le vhost Nginx (redirection HTTP vers HTTPS, en-têtes de sécurité, journaux dédiés) ;
- utilise le certificat wildcard s'il existe, sinon demande un certificat Let's Encrypt dédié ;
- `--auth` place le site derrière un portail d'authentification, `--ws` active WebSocket / SSE ;
- teste la config (`nginx -t`) et **restaure l'ancienne version** en cas d'erreur ;
- si le DNS n'est pas encore propagé, la demande est mise en attente et reprise automatiquement par un timer systemd.

### `lxc-new-project`
Crée un conteneur en clonant un modèle Alpine préparé (`alpine-master`) et lui attribue automatiquement une IP libre.

```bash
lxc-new-project monprojet          # IP choisie dans 10.0.3.100-199
lxc-new-project --list             # IP déjà utilisées
```

### `backup_portfolio.sh`
Sauvegarde quotidienne lancée par un timer systemd :

- bases MariaDB (`mysqldump`), bases SQLite des applis (service arrêté une seconde pour une copie cohérente), fichiers des sites, configuration de l'hôte et `/etc` de chaque conteneur ;
- **chaque archive est vérifiée** (gzip, tar, fin du dump SQL) avant d'être gardée, avec une empreinte `.sha256` ;
- rétention par série, contrôle de l'espace disque, verrou contre les exécutions simultanées ;
- copie distante optionnelle **chiffrée** (AES-256, PBKDF2) avec contrôle d'intégrité après envoi et rattrapage automatique des envois manqués ;
- code de sortie en échec si une sauvegarde rate, pour déclencher une alerte (`OnFailure=`).

## Licence

MIT
