# Instant Access Provider : Dossier d'Architecture — Plateforme IAM Event Streaming

## Objectif

Ce dossier décrit l'architecture d'une plateforme **générique** qui collecte en temps réel les événements de gestion d'identités et d'accès depuis **n'importe quelle source** (Active Directory, applications métier, LDAP, Azure AD…), les normalise en un modèle abstrait commun, et les **publie dans un bus de messages** (topic).

Deux familles de consommateurs sont adressées :

- **SOC** (Security Operations Center) — détection d'anomalies, alertes, corrélation SIEM.
- **Synchronisation événementielle** — propagation des changements d'identités vers d'autres systèmes (IAM, ITSM, RH, Cloud IdP…).

> **Principe fondateur** : un groupe de sécurité AD, un profil applicatif, un groupOfNames LDAP, un rôle AWS IAM sont tous la même entité abstraite : un **Entitlement**. La plateforme ne travaille qu'avec des `Identity`, des `Entitlement` et des `Assignment`.

---

## Structure du dossier

| Fichier | Contenu |
|---|---|
| `docs/00-modele-abstrait.md` | **Fondations** : modèle générique Identity / Entitlement / Assignment |
| `docs/01-contexte-objectifs.md` | Contexte métier, parties prenantes, périmètre |
| `docs/01-iam-platform-functional-spec.md` | SpÃ©cification fonctionnelle de la plateforme |
| `docs/02-architecture-globale.md` | Vue d'ensemble, schéma de flux, composants |
| `docs/03-collecte-ad.md` | Mécanismes de collecte des logs AD (WEF, Winlogbeat, DirSync) |
| `docs/04-traitement-detection.md` | Pipeline de traitement, normalisation, détection des événements métier |
| `docs/05-publication-messaging.md` | Choix du broker, topologie des topics `iam.*`, schémas CloudEvents |
| `docs/06-soc-securite.md` | Cas d'usage SOC, règles de détection, intégration SIEM |
| `docs/11-adapter-sources.md` | **Extensibilité** : AD Adapter, App Adapter (webhook/CDC/polling), LDAP Adapter |

> Documents prÃ©vus, pas encore rÃ©digÃ©s : synchronisation Ã©vÃ©nementielle (pattern Outbox, idempotence, replay), comparatif technologique du broker, sÃ©curitÃ© de l'architecture, roadmap (Entra ID, MFA, UEBA).

---

## Vue macro (résumé)

```
┌──────────────────────────────────────────────────────────────────────┐
│                        SOURCES (extensibles)                         │
│  ┌────────────┐  ┌─────────────────┐  ┌───────────┐  ┌──────────┐  │
│  │ Active Dir │  │  Application A  │  │   LDAP    │  │ Azure AD │  │
│  │  (AD)      │  │  (profils appli)│  │ OpenLDAP  │  │ (v2)     │  │
│  └─────┬──────┘  └────────┬────────┘  └─────┬─────┘  └────┬─────┘  │
└────────╪─────────────────╪─────────────────╪─────────────╪─────────┘
         │                  │                 │             │
         ▼                  ▼                 ▼             ▼
┌──────────────────────────────────────────────────────────────────────┐
│              ADAPTERS (1 par source, modèle générique)               │
│         AD Adapter    App Adapter    LDAP Adapter    Entra Adapter   │
│               ↓ Traduisent en Identity / Entitlement / Assignment    │
└──────────────────────────────┬───────────────────────────────────────┘
                               │ iam.raw.{source}
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│               PIPELINE (Normalisation + Détection)                   │
│         CloudEvents iam.* → Enrichissement → Règles SOC              │
└──────────┬───────────────────┬─────────────────────┬─────────────────┘
           │                   │                     │
           ▼                   ▼                     ▼
  ┌────────────────┐  ┌────────────────┐  ┌──────────────────────┐
