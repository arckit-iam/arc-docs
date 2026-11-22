# arc-docs

Documentation d'architecture et d'exploitation de la plateforme **InstantAccessProvider** (ARC — Agnostic Resources Centralizer).

Ce dépôt regroupe la documentation transverse. La documentation propre à un composant (API, configuration, déploiement) reste dans le README du dépôt concerné.

## Sommaire

### Architecture et conception — [`docs/`](docs/)

| Document | Contenu |
|---|---|
| [intro.md](docs/intro.md) | Introduction et structure du dossier d'architecture |
| [00-modele-abstrait.md](docs/00-modele-abstrait.md) | Modèle abstrait IAM (Identity, Entitlement, Assignment), catalogue d'événements, formats CloudEvents |
| [01-contexte-objectifs.md](docs/01-contexte-objectifs.md) | Contexte métier, parties prenantes, périmètre |
| [01-iam-platform-functional-spec.md](docs/01-iam-platform-functional-spec.md) | Spécification fonctionnelle de la plateforme |
| [02-architecture-globale.md](docs/02-architecture-globale.md) | Vue d'ensemble, flux, composants |
| [03-collecte-ad.md](docs/03-collecte-ad.md) | Collecte des événements Active Directory (WEF, DirSync) |
| [04-traitement-detection.md](docs/04-traitement-detection.md) | Pipeline de traitement et détection |
| [05-publication-messaging.md](docs/05-publication-messaging.md) | Broker, topologie des topics, schémas |
| [06-soc-securite.md](docs/06-soc-securite.md) | Cas d'usage SOC et intégration SIEM |
| [11-adapter-sources.md](docs/11-adapter-sources.md) | Adaptateurs de sources (AD, applications, LDAP) |
| [12-agent-openldap.md](docs/12-agent-openldap.md) | Conception : agent OpenLDAP, collecte LDAP temps réel vers Kafka, annuaire Apache DS (démo et tests) |
| [13-authentification-jwt.md](docs/13-authentification-jwt.md) | Conception : service d'authentification `arc-auth` (bind LDAP, jetons JWT) et protection des API |

### Déploiement et CI/CD

Le déploiement GitOps (Helm, FluxCD) est géré dans un dépôt privé. L'intégration et la mise en production de la plateforme sont proposées par Dédale Solutions en **service payant** : pour en discuter, contactez-nous à [etiennsalle@gmail.com](mailto:etiennsalle@gmail.com). Les guides d'installation et de CI/CD de l'agent collecteur sont dans `agent/docs/` du dépôt principal.

### Documentation des composants

La documentation propre à un composant reste dans son dépôt, par exemple `agent/docs/ARCHITECTURE.md` pour l'agent `iap-agent`.

### Annexes — [`docs/annexes/`](docs/annexes/)

Scripts et fichiers d'exemple référencés par la documentation de collecte AD (`collecte-ad/`).

## Composants

| Dépôt | Rôle |
|---|---|
| `arc-consolidator` | Normalise les événements `iam.raw.*` vers les topics `arc.sync.*` |
| `arc-publisher` | Planifie et publie les événements de provisioning (`arc.provisioning`) |
| `arc-agent-ad` | Agent d'exécution du provisioning Active Directory |
| `arc-agent-openldap` | Agent de provisioning LDAP et de collecte temps réel des changements, validé sur Apache DS (document 12) |
| `arc-auth` *(en conception)* | Authentification LDAP et émission de jetons JWT (document 13) |
| `profile` | Service métier de gestion des profils et permissions ; appelle `arc-publisher` pour créer ou supprimer les groupes AD |
| Dépôt GitOps de déploiement (privé) | Charts Helm et ressources Flux ; intégration proposée en service payant |

## Licence

Copyright © 2026 Dédale Solutions

- Documentation : [CC-BY-4.0](LICENSES/CC-BY-4.0.txt) (Creative Commons Attribution 4.0 International).
- Scripts et fichiers d'exemple de `docs/annexes/` : [EUPL-1.2](LICENSES/EUPL-1.2.txt).

Le dépôt est conforme à la spécification [REUSE](https://reuse.software/) ; les licences applicables sont déclarées dans [REUSE.toml](REUSE.toml).
