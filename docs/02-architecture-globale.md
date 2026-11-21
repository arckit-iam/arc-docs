# 02 — Architecture Globale

## 1. Principes directeurs

| Principe | Description |
|---|---|
| **Event-Driven** | Les sources sont la vérité. Tout changement est un evenement immuable. |
| **Decouplage** | Aucun consommateur n'interroge les sources directement. |
| **Single Source of Truth** | Kafka contient l'historique des faits. L'etat courant est une projection. |
| **Idempotence** | Les consommateurs et les projections tolerent le rejeu sans effet de bord. |
| **Defense in Depth** | Collecte, transport, stockage et exposition sont securises et audites. |
| **Haute disponibilite** | Les collecteurs et les traitements sont deployables en parallele. |
| **Segmentation** | Un collecteur Fluent Bit par zone de securite ou par region. |

---

## 2. Vue d'ensemble des couches

```
╔══════════════════════════════════════════════════════════════════════╗
║  COUCHE 1 — SOURCES                                                  ║
║                                                                      ║
║  AD Domain Controllers  ──[WEF / Event Forwarding]──► WEC           ║
║  ISVD / Equipements     ──[Syslog UDP/TCP/TLS]──────► Collecteur    ║
║  Serveurs Linux         ──[Syslog / auditd]─────────► Collecteur    ║
║  Applications           ──[Webhook / API REST / CDC]► Collecteur    ║
╚══════════════════════════════════════════════════════════════════════╝
                        │
╔═══════════════════════▼══════════════════════════════════════════════╗
║  COUCHE 2 — COLLECTEURS FLUENT BIT                                   ║
║                                                                      ║
║  Fluent Bit tourne sur les serveurs de collecte (WEC, bastions, etc.)║
║                                                                      ║
║  - INPUT   : winlog, syslog, tail, http                              ║
║  - FILTER  : normalisation minimale, tags source/zone                ║
║  - OUTPUT  : Kafka (iam.raw.{sourceSystem})                          ║
║                                                                      ║
║  Plusieurs instances en parallele :                                  ║
║  FB-Tier0, FB-Prod, FB-Cloud ...                                     ║
╚═════════════════════════════════╪════════════════════════════════════╝
                                  │
╔═════════════════════════════════▼════════════════════════════════════╗
║  COUCHE 3 — STREAM PROCESSOR + TOPICS KAFKA                          ║
║                                                                      ║
║  iam.raw.{sourceId}      ← evenements bruts par source (interne)    ║
║  iam.identity            ← evenements normalises Identity            ║
║  iam.entitlement         ← evenements normalises Entitlement         ║
║  iam.assignment          ← evenements normalises Assignment          ║
║  iam.consolidated        ← events de projection etat (upsert-ready)  ║
║  iam.alert               ← alertes SOC                               ║
║  iam.audit               ← audit trail long terme                    ║
║  iam.dlq                 ← dead-letter queue                         ║
╚═════════════════════════════════╪════════════════════════════════════╝
                                  │
╔═════════════════════════════════▼════════════════════════════════════╗
║  COUCHE 4 — INSTANTACCESSPUBLISHER (JAVA) + POSTGRESQL               ║
║                                                                      ║
║  Service Java de projection d'etat:                                  ║
║  - Consomme iam.consolidated                                         ║
║  - Construit les tables consolidees T0                               ║
║  - Maintient identity, entitlement, assignment                       ║
║  - Offre un referentiel temps reel requetable                        ║
╚══════════════════════════════════════════════════════════════════════╝
```

---

## 3. Description des composants

### 3.1 Sources

| Source | Transport vers Fluent Bit | Notes |
|---|---|---|
| **Active Directory (DCs)** | WEF vers WEC puis lecture `ForwardedEvents` | Aucun agent sur les DCs |
| **Active Directory (fallback)** | DirSync LDAP (polling) | Filet de securite en cas de trous Event Logs |
| **ISVD / equipements reseau** | Syslog UDP/TCP/TLS | Format RFC 5424 ou CEF |
| **Serveurs Linux** | Syslog / auditd | Collecte locale ou remote |
| **Applications metier** | Webhook HTTP / API | Adapters progressifs selon besoins |

### 3.2 Collecte Fluent Bit

Fluent Bit est la brique de collecte standard. Il remplace le developpement d'un agent Java de collecte.

**Responsabilites de Fluent Bit :**
- Lire les journaux locaux (ex: `ForwardedEvents` sur WEC)
- Recevoir des flux reseau (syslog/http selon zone)
- Ajouter des metadonnees de routage (`sourceSystem`, `sourceZone`, `collectorHost`)
- Publier vers Kafka avec accusés de reception et reprise

**Ce que Fluent Bit ne fait pas :**
- Normalisation metier IAM complete
- Correlation et detection SOC
- Materialisation de l'etat courant

### 3.3 Stream Processor

Responsable de :
- Consommer les topics `iam.raw.*`
- Normaliser en CloudEvents (modele IAM abstrait)
- Enrichir (LDAP/CMDB) y compris les **UO** Active Directory (DN parent, OU immediate, chemin d'OU)
- Detecter les patterns et publier `iam.alert`
- Publier des messages de projection dans `iam.consolidated`

### 3.4 InstantAccessPublisher (nouveau role)

`InstantAccessPublisher` devient un service de **projection d'etat** :
- Consomme `iam.consolidated`
- Ecrit en PostgreSQL des tables consolidees :
  - `identity_state`
  - `entitlement_state`
  - `assignment_state`
- Maintient un etat T0 temps reel et rejouable
- Gere l'idempotence (upsert par cle metier stable)

### 3.5 Bus de messages (Kafka)

Kafka reste le registre de faits immuable :
- Retention des faits (90 jours recommandes)
- Rejeu natif
- Compatibilite schema via Schema Registry

### 3.6 Consommateurs

| Famille | Role | Protocole |
|---|---|---|
| SOC | Ingestion SIEM + SOAR | Kafka Consumer |
| Sync IAM | Provisioning/deprovisioning | Kafka Consumer, REST/SCIM |
| Referential interne | Etat consolide T0 | PostgreSQL (alimente par InstantAccessPublisher) |

---

## 4. Flux de donnees detaille

```
DC-01 genere Event 4720 (creation compte "john.doe")
  │
  ├─[WEF push]─► WEC Server
  │                   │
  │           ┌───────▼──────────────────────────────────────┐
  │           │  Fluent Bit (sur WEC)                        │
  │           │  - Input winlog ForwardedEvents              │
  │           │  - Tag sourceSystem=activedirectory          │
  │           │  - Output Kafka iam.raw.activedirectory      │
  │           └─────────────┬────────────────────────────────┘
  │                         │
  │           ──────────────► topic: iam.raw.activedirectory
  │                         │
  │           Stream Processor
  │           - Normalise en CloudEvents IAM
  │           - Enrichit: manager LDAP + UO
  │           - Detecte et publie iam.alert
  │           - Produit iam.consolidated
  │                         │
  │           ──────────────► topic: iam.consolidated
  │                         │
  │           InstantAccessPublisher (Java)
  │           - Upsert PostgreSQL identity/entitlement/assignment
  │                         │
  │                 ──────► Referentiel consolide (etat T0)
```

---

## 5. Decisions d'architecture (ADR)

### ADR-001 — WEF vs agent sur chaque DC
**Decision** : WEF + DirSync fallback  
**Raison** : Empreinte minimale sur les DCs, mecanisme natif Windows, reprise fiable.

### ADR-002 — Fluent Bit plutot qu'un agent Java de collecte
**Decision** : Standardiser la collecte sur Fluent Bit deploye sur les serveurs de collecte  
**Raison** : Composant mature, leger, configurable, moins de code specifique a maintenir.

### ADR-003 — Separation collecte / traitement / projection
**Decision** : Fluent Bit collecte, Stream Processor normalise/detecte, InstantAccessPublisher materialise l'etat  
**Raison** : Responsabilites claires, scalabilite independante, operations simplifiees.

### ADR-004 — Topic de projection consolide
**Decision** : Ajouter `iam.consolidated` pour alimenter le referentiel d'etat  
**Raison** : Evite de recalculer l'etat en lisant plusieurs topics cote service de projection.

### ADR-005 — Schema principal CloudEvents, alignement SCIM partiel
**Decision** : Conserver le schema IAM abstrait et source-agnostique, avec alignement SCIM quand pertinent  
**Raison** : SCIM est utile pour l'interoperabilite mais ne couvre pas toute la finesse requise multi-annuaires (notamment certains contextes techniques).