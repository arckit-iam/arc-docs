# 05 — Publication : Bus de Messages, Topic consolide et Referentiel PostgreSQL

> Ce document utilise la nomenclature du modele IAM defini dans `docs/00-modele-abstrait.md`.
> La collecte est assuree par Fluent Bit sur les serveurs de collecte (WEC, collecteurs syslog, etc.).

## 1. Topologie cible des topics Kafka

```
                     ┌──────────────────────────────────────────┐
                     │              KAFKA CLUSTER               │
                     │                                          │
  Fluent Bit ──────► │  iam.raw.activedirectory (interne)      │
  Fluent Bit ──────► │  iam.raw.app-a           (interne)      │
  Fluent Bit ──────► │  iam.raw.ldap            (interne)      │
                     │  └─ 1 topic raw par source, RF:3, 7j     │
                     │                                          │
  Stream        ┌──► │  iam.identity          (public)         │
  Processor ────┤    │  iam.entitlement       (public)         │
  (normalise +  ├──► │  iam.assignment        (public)         │
   enrichit +   ├──► │  iam.alert             (soc)            │
   detecte)     ├──► │  iam.audit             (archivage)      │
                └──► │  iam.consolidated      (interne proj.)  │
                     │                                          │
                     └──────────────────────────────────────────┘
                                       │
                                       ▼
                         InstantAccessPublisher (Java)
                                       │
                                       ▼
                                  PostgreSQL
                (identity_state / entitlement_state / assignment_state)
```

---

## 2. Description des topics

### `iam.raw.{sourceSystem}` — Interne (1 topic par source)

| Propriete | Valeur |
|---|---|
| Visibilite | Interne (pipeline uniquement, ACL restreint) |
| Format | JSON brut propre a chaque source |
| Exemples | `iam.raw.activedirectory`, `iam.raw.app-a`, `iam.raw.ldap` |
| Partitionnement | Par `sourceId` |
| Retention | 7 jours |
| Compaction | Non |

### `iam.identity` — Evenements Identity

| Propriete | Valeur |
|---|---|
| Visibilite | Public (IAM, SOC, Audit) |
| Format | CloudEvents 1.0 + JSON Schema |
| Partitionnement | Par `data.identity.id` |
| Retention | 90 jours |
| Compaction | Non |

Types: `iam.identity.created`, `iam.identity.updated`, `iam.identity.enabled`, `iam.identity.disabled`, `iam.identity.deleted`

### `iam.entitlement` — Evenements Entitlement

| Propriete | Valeur |
|---|---|
| Visibilite | Public |
| Format | CloudEvents 1.0 + JSON Schema |
| Partitionnement | Par `data.entitlement.id` |
| Retention | 90 jours |
| Compaction | Non |

Types: `iam.entitlement.created`, `iam.entitlement.updated`, `iam.entitlement.deleted`

### `iam.assignment` — Evenements Identity -> Entitlement

| Propriete | Valeur |
|---|---|
| Visibilite | Public |
| Format | CloudEvents 1.0 + JSON Schema |
| Partitionnement | Par `data.identity.id` |
| Retention | 90 jours |
| Compaction | Non |

Types: `iam.assignment.added`, `iam.assignment.removed`

### `iam.consolidated` — Topic de projection d'etat

| Propriete | Valeur |
|---|---|
| Visibilite | Interne (service de projection) |
| Format | Evenement de projection (upsert/delete) |
| Partitionnement | Par `entityType + entityKey` |
| Retention | 30 jours |
| Compaction | Oui (recommande) |

Ce topic alimente InstantAccessPublisher pour maintenir l'etat T0 en base, sans recalcul complet sur plusieurs topics.

### `iam.alert` — Alertes SOC

| Propriete | Valeur |
|---|---|
| Visibilite | SOC uniquement |
| Format | CloudEvents 1.0 + extension alert |
| Partitionnement | Par severite |
| Retention | 90 jours |
| Compaction | Non |

### `iam.audit` — Journal long terme

| Propriete | Valeur |
|---|---|
| Visibilite | Audit / conformite |
| Format | JSON signe |
| Partitionnement | Par mois |
| Retention | 365 jours |
| Compaction | Non |

---

## 3. Positionnement schema : IAM abstrait et compatibilite SCIM

Le contrat principal reste le schema IAM abstrait source-agnostique.

SCIM est utilise comme reference de modelisation quand utile, mais n'est pas impose comme format unique sur Kafka.

Raisons:
- besoin de champs evenementiels (acteur, regle SOC, contexte technique),
- couverture multi-sources heterogenes (AD, LDAP, applications, etc.),
- besoin de granularite superieure sur certaines metadonnees (ex: UO AD, event IDs natifs, contexte de collecte).

Decision:
- Kafka interne/externe: CloudEvents + schema IAM abstrait,
- exposition API: projection SCIM possible si necessaire,
- pas de regression fonctionnelle sur la finesse actuelle.

---

## 4. Champs attendus pour les UO Active Directory

Les UO doivent etre captures dans la partie identity pour permettre filtrage, gouvernance et segmentation.

Exemple (dans `data.identity.metadata`):

```json
{
  "samAccountName": "john.doe",
  "upn": "john.doe@corp.example.com",
  "primaryOu": "OU=Users,OU=Paris,DC=corp,DC=example,DC=com",
  "organizationalUnits": [
    "OU=Users,OU=Paris,DC=corp,DC=example,DC=com",
    "OU=Paris,DC=corp,DC=example,DC=com"
  ]
}
```

---

## 5. InstantAccessPublisher : nouveau role

`InstantAccessPublisher` ne collecte plus les evenements source. Son role devient la materialisation d'etat.

### 5.1 Fonctionnement

1. Consommer `iam.consolidated`.
2. Interpreter l'operation (`UPSERT`, `DELETE`) et `entityType` (`identity`, `entitlement`, `assignment`).
3. Faire un upsert idempotent dans PostgreSQL.
4. Exposer un referentiel a jour en temps reel (etat T0).

### 5.2 Tables cibles PostgreSQL

- `identity_state`
- `entitlement_state`
- `assignment_state`

### 5.3 Principes d'ecriture

- cle metier stable par type d'entite,
- upsert idempotent,
- horodatage de derniere mise a jour,
- gestion des suppressions logiques ou physiques selon besoins audit.

---

## 6. Configuration Kafka recommandee

### Producer (Fluent Bit -> iam.raw.*)

- `acks=all`
- retries actifs
- buffer disque local Fluent Bit
- TLS obligatoire

### Consumer (InstantAccessPublisher)

- `group.id=instantaccesspublisher-consolidator`
- `auto.offset.reset=earliest`
- `enable.auto.commit=false`
- commits apres transaction PostgreSQL reussie
- traitement idempotent (upsert)

---

## 7. Monitoring

Metriques minimales a suivre:

| Metrique | Seuil alerte | Signification |
|---|---|---|
| `consumer_lag` sur `iam.consolidated` | > 1000 | Projection en retard |
| `producer_error_rate` Fluent Bit | > 0 | Risque de perte de collecte |
| taux d'erreur upsert PostgreSQL | > 0 | Probleme schema/qualite donnees |
| `iam.dlq` offset rate | > 0 | Erreurs de parsing/enrichissement |
| `under_replicated_partitions` | > 0 | Probleme cluster Kafka |