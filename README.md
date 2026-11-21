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

### Déploiement et CI/CD

Les guides de déploiement et de CI/CD sont dans le dépôt `arc-kubeorchestrator`, à côté des charts Helm et des ressources Flux : `docs/DEPLOY.md` et `docs/CI-CD.md`.

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
| `arc-kubeorchestrator` | Charts Helm, ressources Flux et documentation de déploiement |

## Licence

Copyright © 2026 Dédale Solutions

- Documentation : [CC-BY-4.0](LICENSES/CC-BY-4.0.txt) (Creative Commons Attribution 4.0 International).
- Scripts et fichiers d'exemple de `docs/annexes/` : [EUPL-1.2](LICENSES/EUPL-1.2.txt).

Le dépôt est conforme à la spécification [REUSE](https://reuse.software/) ; les licences applicables sont déclarées dans [REUSE.toml](REUSE.toml).
