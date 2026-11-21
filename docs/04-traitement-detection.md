# 04 — Traitement et Détection des Événements

> Le pipeline de traitement est **source-agnostique**. Il reçoit des événements bruts depuis Kafka (collectés par Fluent Bit) et produit des CloudEvents normalisés sur le modèle `Identity / Entitlement / Assignment`. Voir `docs/00-modele-abstrait.md`.

## 1. Pipeline de traitement

Le Stream Processor transforme les événements bruts Windows en événements métier normalisés et enrichis.

```
iam.raw.{source}  ← un topic par source (AD, app-a, ldap…)
     │
     ▼
┌─────────────────────────────────────────────────────┐
│  ÉTAPE 1 — Parsing & Validation                     │
│  - Parser le XML Windows Event                      │
│  - Valider les champs obligatoires                  │
│  - Rejeter les événements malformés (DLQ)           │
└────────────────────────┬────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│  ÉTAPE 2 — Normalisation (→ CloudEvents)            │
│  - Mapper les champs Windows vers le schéma métier  │
│  - Ajouter: source, type, time, specversion         │
│  - Générer un eventId stable (idempotent)           │
└────────────────────────┬────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│  ÉTAPE 3 — Enrichissement                           │
│  - Lookup LDAP / API source : département, manager, UO │
│  - Lookup CMDB : sensibilité de l'Entitlement        │
│  - Résoudre ID natif → ID plateforme (UUID)          │
│  - Résoudre Entitlements imbriqués (récursif)        │
└────────────────────────┬────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│  ÉTAPE 4 — Détection de patterns                    │
│  - Règles statiques (Entitlements sensibles connus)  │
│  - Règles temporelles (hors heures ouvrables)        │
│  - Corrélation (X assignements en Y minutes)         │
└────────┬───────────────┬────────────────────────────┘
         │               │                  │
         ▼               ▼                  ▼
  iam.identity    iam.entitlement     iam.assignment
  + iam.alert     + iam.consolidated
```

---

## 2. Normalisation — Schéma CloudEvents

Tous les événements publiés respectent **CloudEvents 1.0** avec le modèle abstrait IAM.

### 2.1 Structure de base

```json
{
  "specversion": "1.0",
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "source": "ad://corp.example.com",
  "type": "com.example.iam.identity.created",
  "time": "2026-04-02T14:32:11.123Z",
  "datacontenttype": "application/json",
  "schemaurl": "https://schema-registry.internal/iam-events/v3",
  "iamsourcetype": "activedirectory",

  "data": {
    "identity": {
      "id": "f47ac10b-...",
      "externalId": "S-1-5-21-XXXX-YYYY-ZZZZ-1105",
      "sourceSystem": "ad://corp.example.com",
      "type": "user",
      "displayName": "John Doe",
      "metadata": {
        "samAccountName": "john.doe",
        "upn": "john.doe@corp.example.com",
        "department": "IT",
        "organizationalUnits": [
          "OU=Users,OU=Paris,DC=corp,DC=example,DC=com",
          "OU=Paris,DC=corp,DC=example,DC=com"
        ],
        "primaryOu": "OU=Users,OU=Paris,DC=corp,DC=example,DC=com"
      }
    },
    "actor": {
      "externalId": "S-1-5-21-...-ADMIN",
      "displayName": "admin.service",
      "isServiceAccount": true
    },
    "context": {
      "sourceNativeEventId": "4720",
      "originDc": "DC-01.corp.example.com"
    }
  }
}
```

### 2.2 Types d'événements (type field)

| Type CloudEvent | Description | Sources possibles |
|---|---|---|
| `com.example.iam.identity.created` | Identité créée | AD (4720), App A, LDAP |
| `com.example.iam.identity.enabled` | Identité activée | AD (4722), App A |
| `com.example.iam.identity.disabled` | Identité désactivée | AD (4725), App A |
| `com.example.iam.identity.deleted` | Identité supprimée | AD (4726), App A, LDAP |
| `com.example.iam.identity.updated` | Attributs modifiés | AD (4738), App A, LDAP |
| `com.example.iam.entitlement.created` | Entitlement créé | AD (4727/4731/4754), App A, LDAP |
| `com.example.iam.entitlement.updated` | Entitlement modifié | AD, App A |
| `com.example.iam.entitlement.deleted` | Entitlement supprimé | AD (4730/4734/4758), App A |
| `com.example.iam.assignment.added` | Affectation ajoutée | AD (4728/4732/4756), App A, LDAP |
| `com.example.iam.assignment.removed` | Affectation retirée | AD (4729/4733/4757), App A, LDAP |

### 2.3 Événement `iam.assignment.added`

> Voir le schéma complet (AD et Application A) dans `docs/00-modele-abstrait.md` section 6.

### 2.4 Positionnement SCIM

Le format principal reste **CloudEvents + schéma IAM abstrait**.

SCIM est utilisé comme référence de nommage quand cela apporte de l'interopérabilité (`externalId`, `displayName`, `emails`, `groups`), mais il n'est pas imposé comme contrat unique car :
- certaines sources non-SCIM exposent des champs techniques non standards,
- les besoins SOC et audit demandent des champs de contexte évènementiel,
- la granularité multi-annuaires (AD, LDAP, applications) dépasse le coeur SCIM sans extensions.

En pratique :
- topic normalisé : schéma IAM abstrait,
- compatibilité SCIM : projection possible en sortie API,
- aucun verrouillage à un annuaire spécifique.

---

## 3. Enrichissement

### 3.1 Cache de référentiel source

Le pipeline maintient un **cache d'attributs** par source (LDAP, API applicative…) invalidé par les événements de modification. Cela évite une requête synchrone pour chaque événement.

```
Événement reçu
    │
    ├─► Cache hit ? ──► Utiliser les données du cache
    │
    └─► Cache miss ──► Requête LDAP ──► Mettre en cache (TTL = 5 min)
                        │
                        └─► Si objet introuvable → émettre champ "enrichmentFailed: true"
```

**Attributs LDAP enrichis** :
- `displayName`, `mail`, `department`, `title`, `manager`
- `organizationalUnits` (chemin UO complet et UO parent immédiate)
- `memberOf` (direct seulement, les imbriqués sont résolus si nécessaire)
- `whenCreated`, `accountExpires`, `userAccountControl`

### 3.2 Classification des Entitlements sensibles

Un référentiel des **Entitlements sensibles** est maintenu dans le Source Registry (voir `docs/11-adapter-sources.md`). Il couvre indifféremment les groupes AD et les profils applicatifs :

```yaml
# Source: ad://corp.example.com
sensitiveEntitlements:
  - pattern: "Domain Admins"
    sensitivity: CRITICAL
  - pattern: "Backup Operators"
    sensitivity: HIGH
  - pattern: "VPN-*"
    sensitivity: MEDIUM

# Source: app://app-a.example.com
sensitiveEntitlements:
  - pattern: "PROFIL_ADMIN_*"
    sensitivity: HIGH
  - pattern: "PROFIL_EXPORT_PAIE"
    sensitivity: CRITICAL
    reason: "Accès export données de paie"
```

Le Stream Processor **consulte le Source Registry** pour enrichir `entitlement.sensitivityLevel`.

### 3.3 Résolution ID natif → ID plateforme

Chaque source utilise ses propres identifiants (SID AD, UUID applicatif, DN LDAP). Le pipeline résout ces IDs natifs en **UUID de plateforme stables** via un cache `{sourceSystem}:{externalId} → UUID`. Ce mécanisme permettra à terme de **corréler le même utilisateur réel** entre plusieurs sources.

---

## 4. Règles de détection (pour topic `iam.alert`)

### 4.1 Règles statiques (indépendantes de la source)

```kotlin
// S'applique à iam.assignment quelle que soit la source
stream("iam.assignment")
    .filter { event -> event.type == "com.example.iam.assignment.added" }
    .filter { event -> event.data.entitlement.sensitivityLevel in listOf("HIGH", "CRITICAL") }
    .mapValues { event ->
        AlertEvent(
            severity = mapSeverity(event.data.entitlement.sensitivityLevel),
            ruleId = "RULE-001",
            ruleName = "Affectation à un Entitlement privilégié",
            // Fonctionne pour Domain Admins (AD) et PROFIL_EXPORT_PAIE (App A)
            description = "${event.data.identity.displayName} affecté à ${event.data.entitlement.name} [${event.source}]",
            mitreTactic = "Privilege Escalation",
            mitreTechnique = "T1078",
            originalEvent = event
        )
    }
    .to("iam.alert")
```

### 4.2 Règles temporelles

| Règle | Condition | Sévérité |
|---|---|---|
| `RULE-002` | Identité créée en dehors des heures ouvrables | MEDIUM |
| `RULE-003` | Affectation à Entitlement CRITICAL hors heures ouvrables | HIGH |
| `RULE-004` | Identité créée ET affectée à Entitlement CRITICAL dans les 5 min | CRITICAL |
| `RULE-005` | Plus de 10 affectations en moins de 1 minute par le même acteur | HIGH |
| `RULE-006` | Compte service affecté à Entitlement interactif | MEDIUM |

### 4.3 Corrélation temporelle (fenêtre glissante)

```
RULE-004 : Création Identity + Affectation Entitlement CRITICAL en < 5 min

Stream A: iam.identity   (iam.identity.created)
Stream B: iam.assignment (iam.assignment.added, entitlement.sensitivityLevel=CRITICAL)

JOIN sur identity.id
FENÊTRE: tumbling 5 minutes
→ Si les deux événements partagent la même identity dans la fenêtre : ALERTE CRITIQUE
→ Fonctionne pour AD (4720 + 4728) ET applications (USER_CREATED + USER_PROFILE_ASSIGNED)
```

Implémentation : **Kafka Streams** avec `JoinWindows.ofTimeDifferenceWithNoGrace(5 minutes)` ou équivalent Flink `TumblingEventTimeWindows`.

### 4.4 Dead Letter Queue (DLQ)

```
iam.raw.{source}
    │
    ├──► Traitement OK ──► iam.identity / iam.entitlement / iam.assignment / iam.alert
    │
    └──► Erreur parsing / enrichissement ──► iam.dlq
                                                  │
                                          Alerte opérationnelle
                                          + Tableau de bord DLQ
```

---

## 5. Exemples de mapping complets — deux sources

### 5.1 AD : Event 4728 → `iam.assignment` + `iam.alert`

#### Entrée (log Windows brut)

```xml
EventID: 4728
Time: 2026-04-02T02:17:43.000Z  ← 2h17 du matin !
Computer: DC-01.corp.example.com
SubjectUserName: compromise-account
TargetUserName: Domain Admins
MemberName: CN=malicious.user,OU=...
```

#### Sortie topic `iam.assignment`

```json
{
  "type": "com.example.iam.assignment.added",
  "source": "ad://corp.example.com",
  "iamsourcetype": "activedirectory",
  "data": {
    "identity": { "displayName": "malicious.user", "type": "user" },
    "entitlement": { "name": "Domain Admins", "type": "security-group", "sensitivityLevel": "CRITICAL" },
    "actor": { "displayName": "compromise-account" },
    "context": { "isOutsideBusinessHours": true, "isPrivilegedEntitlement": true, "sourceNativeEventId": "4728" }
  }
}
```

#### Sortie topic `iam.alert` (RULE-001 + RULE-003 déclenchées)

```json
{
  "type": "com.example.iam.alert",
  "severity": "CRITICAL",
  "rules": ["RULE-001", "RULE-003"],
  "description": "Affectation à Entitlement CRITICAL [Domain Admins] hors heures ouvrées — source: ad://corp.example.com",
  "mitreTactic": "Privilege Escalation",
  "mitreTechnique": "T1078"
}
```

---

### 5.2 Application A : affectation profil sensible → mêmes alertes

#### Entrée (webhook Application A)

```json
{ "eventType": "USER_PROFILE_ASSIGNED", "userId": "user-00234",
  "profileId": "profile-003", "profileName": "PROFIL_EXPORT_PAIE",
  "assignedBy": "user-admin-001", "timestamp": "2026-04-02T02:19:00Z" }
```

#### Sortie topic `iam.assignment` (même schéma qu'AD !)

```json
{
  "type": "com.example.iam.assignment.added",
  "source": "app://app-a.example.com",
  "iamsourcetype": "business-application",
  "data": {
    "identity": { "externalId": "user-00234", "type": "user", "displayName": "Jane Smith" },
    "entitlement": { "externalId": "profile-003", "name": "PROFIL_EXPORT_PAIE",
                     "type": "app-profile", "sensitivityLevel": "CRITICAL" },
    "context": { "isOutsideBusinessHours": true, "isPrivilegedEntitlement": true }
  }
}
```

**RULE-001 et RULE-003 se déclenchent sans aucune modification des règles SOC.**  
Le champ `iamsourcetype` permet d'affiner les playbooks SOAR (réponse AD ≠ réponse App A), mais l'alerte elle-même est identique.
