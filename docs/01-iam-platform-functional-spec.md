# InstantAccessProvider — Spécification Fonctionnelle Plateforme IAM V1

**Version:** 1.0  
**Date:** Mai 2026  
**Statut:** Spécification V1  
**Scope:** Système de gestion des identités, des rôles et des droits d'accès

---

## Table des matières

1. [Vue générale et objectifs](#1-vue-générale-et-objectifs)
2. [Architecture microservices proposée](#2-architecture-microservices-proposée)
3. [Référentiel des identités](#3-référentiel-des-identités)
4. [Données de contexte : Postes et Contrats](#4-données-de-contexte--postes-et-contrats)
5. [Modèle de rôles](#5-modèle-de-rôles)
6. [Mappings entre rôles et ressources de sécurité](#6-mappings-entre-rôles-et-ressources-de-sécurité)
7. [Système d'authentification adaptable](#7-système-dauthentification-adaptable)
8. [Profils et autorisations d'accès](#8-profils-et-autorisations-daccès)
9. [Récupération de l'image des ressources (T0)](#9-récupération-de-limage-des-ressources-t0)
10. [Affectations de rôles : manuelles et automatiques](#10-affectations-de-rôles--manuelles-et-automatiques)
11. [Ordres d'assignation et cycle de vie](#11-ordres-dassignation-et-cycle-de-vie)
12. [Gestion des clés d'identification](#12-gestion-des-clés-didentification)
13. [Gestion des écarts (compliance drift)](#13-gestion-des-écarts-compliance-drift)
14. [Validation multi-niveaux des rôles](#14-validation-multi-niveaux-des-rôles)
15. [Roadmap V2](#15-roadmap-v2)

---

## 1. Vue générale et objectifs

### 1.1 Objectif

InstantAccessProvider V1 est une plateforme **centralisée de gouvernance des identités et des accès (IAM)** qui :

- **Unifie** les identités (collaborateurs, comptes applicatifs, comptes services) provenant de sources multiples
- **Normalise** les droits d'accès sous forme de **rôles** portables
- **Orchestre** la distribution des droits vers les systèmes cibles (Active Directory, applications, cloud, etc.)
- **Audite** les opérations et maintient une traçabilité complète
- **Détecte et corrige** les écarts entre état souhaité et état réel

### 1.2 Entrées et sorties

| Flux | Format | Description |
|-----|--------|-------------|
| **Entrée** | `arc.sync.identity`, `arc.sync.entitlement`, `arc.sync.assignment` | 3 Topics Kafka produits par **arc-consolidator** contenant l'image normalisée des identités, des entitlements et des affectations de tous les systèmes sources (AD, applications, systèmes RH). Chaque message inclut un champ `system` (e.g., `ad://corp.example.com`) permettant de déterminer la source et la cible. |
| **Sortie** | `arc.provisioning` | Topics Kafka contenant les ordres d'assignation (job) à envoyer aux systèmes cibles via arc-publisher |

### 1.3 Principes clés

- **Clé d'identification unique** par personne : socle de toute règle métier
- **Règles d'affectation automatiques** : basées sur profil, poste, attributs
- **Validation multi-niveaux** : approbations requises avant envoi effectif
- **Cycle de vie contrôlé** : annulation possible avant exécution, traçabilité après
- **Multi-tenancy prêt** : architecture pensée pour SaaS futur
- **Audit complet** : chaque opération tracée et queryable

---

## 2. Architecture microservices proposée

### 2.1 Services principaux

```
┌─────────────────────────────────────────────────────────────┐
│                        API Gateway                          │
│              (Authentification, Rate limiting)              │
└─────────┬──────────────────────────────────────────────────┘
          │
     ┌────┴─────┬──────────┬──────────┬──────────┬──────────┐
     │           │          │          │          │          │
     ▼           ▼          ▼          ▼          ▼          ▼
┌─────────┐ ┌──────────┐ ┌──────┐ ┌────────┐ ┌────────┐ ┌──────┐
│ Identity│ │   Role   │ │Config│ │Assign. │ │ Audit  │ │ Drift│
│ Service │ │ Service  │ │Svc   │ │Service │ │ Svc    │ │ Svc  │
└─────────┘ └──────────┘ └──────┘ └────────┘ └────────┘ └──────┘
     │           │          │          │          │          │
     └───────────┴──────────┴──────────┴──────────┴──────────┘
                        │
            ┌───────────┴─────────────┐
            │                         │
            ▼                         ▼
        PostgreSQL               Redis Cache
       (État persistant)         (Sessions, cache)
            │
     ┌──────┴──────────┐
     │                 │
     ▼                 ▼
 arc.sync topics   arc.provisioning topics
 (Entrée)          (Sortie)
```

### 2.2 Description des services

| Service | Responsabilités |
|---------|-----------------|
| **Identity Service** | Gestion du référentiel des identités, des clés d'identification, des données contextuelles (postes, contrats) |
| **Role Service** | Modèle de rôles, création/modification/suppression, validation multi-niveaux |
| **Assignment Service** | Affectation des rôles aux identités, gestion du cycle de vie des ordres (job), appel de l'API `arc-publisher` (`POST /jobs`) avec les dates d'effet |
| **Config Service** | Configuration par tenant (clients), gestion des règles d'affectation automatiques, mappings clé → account, niveaux de validation |
| **Audit Service** | Logging de toutes les opérations, traçabilité, requêtes d'audit |
| **Drift Service** | Détection des écarts, alertes, rapports de non-conformité |

**Composants externes (hors IAM Core) :**
- **arc-publisher** : persiste les jobs en PostgreSQL, recalcule périodiquement les jobs `pending` et publie dans `arc.provisioning.*` au bon moment.
- **Agents (un par cible)** : consomment `arc.provisioning.*` en temps réel et exécutent les ordres, sans logique de temporalité.

### 2.3 Communication inter-services

- **Synchrone** (REST/gRPC) : opérations temps réel, lectures urgentes
- **Asynchrone** (Kafka) : publications d'événements, notifications d'état, synchronisation
- **Cache distribué** : Redis pour sessions, permissions, cache de configuration

---

## 3. Référentiel des identités

### 3.1 Structure de l'entité Identity

Chaque identité est l'abstraction d'une **personne, d'un compte applicatif ou d'un compte service** capables d'avoir des droits.

| Champ | Type | Obligatoire | Description |
|-------|------|-------------|-------------|
| `id` | UUID | ✓ | Identifiant unique stable généré par la plateforme |
| `identificationKey` | String | ✓ | **Clé d'identification** unique par tenant (cf. §12) |
| `system` | String | ✓ | Système source (champ provenant de `arc.sync.identity.system`, e.g., `ad://corp.example.com`, `app://sirh.example.com`) |
| `externalId` | String | ✓ | Identifiant dans le système source (SID, UID, email…) |
| `type` | Enum | ✓ | `person` / `service` / `machine` / `guest` |
| `displayName` | String | ✓ | Nom lisible (e.g., "Jean Dupont") |
| `email` | String | Opt | Adresse email |
| `status` | Enum | ✓ | `active` / `inactive` / `suspended` / `terminated` |
| `createdAt` | DateTime | ✓ | Horodatage de création dans la plateforme |
| `createdBy` | UUID | ✓ | Qui a créé l'identité (user ID ou système) |
| `updatedAt` | DateTime | ✓ | Dernière mise à jour |
| `metadata` | Map | Opt | Champs libres additionnels provenant de l'événement `arc.sync.identity` (department, costCenter…) |

### 3.2 Cycle de vie d'une identité

```
[Création] → [Active] ⟷ [Suspended] → [Terminated]
```

- **Création** : manuelle (UI admin) ou automatique (sync depuis système source)
- **Active** : peut recevoir des rôles et droits
- **Suspended** : gels temporaire, droits maintenus mais non-effectifs
- **Terminated** : fin d'emploi, tous les ordres en attente sont annulés, audit de fin

### 3.3 Import initial (migration)

Lors de la migration d'un client existant :

1. Charger les identités depuis le système source
2. Pour chaque identité, la **clé d'identification peut être fournie ou générée** (cf. §12)
3. Si fournie, vérifier son unicité dans le tenant
4. État initial : `active` si compte actif dans la source, sinon `inactive`

---

## 4. Données de contexte : Postes et Contrats

### 4.1 Modèle de données : Contrat/Poste

Les droits d'accès doivent être **bornés par le contexte professionnel** de la personne.

| Champ | Type | Obligatoire | Description |
|-------|------|-------------|-------------|
| `id` | UUID | ✓ | Identifiant du contrat/poste |
| `identityId` | UUID | ✓ | Lien vers l'Identity |
| `title` | String | ✓ | Titre du poste (e.g., "Responsable IT") |
| `department` | String | ✓ | Département/Unité (e.g., "IT", "RH", "Finance") |
| `team` | String | Opt | Équipe (e.g., "Infrastructure") |
| `manager` | UUID | Opt | Lien vers l'Identity du manager |
| `location` | String | Opt | Localisation géographique (e.g., "Paris", "Lyon") |
| `costCenter` | String | Opt | Centre de coûts |
| `startDate` | Date | ✓ | Début du contrat/poste |
| `endDate` | Date | Opt | Fin du contrat (null = contrat permanent) |
| `status` | Enum | ✓ | `active` / `suspended` / `ended` |
| `metadata` | Map | Opt | Champs libres (securityClearance, skills…) |

### 4.2 Utilisation du contexte Contrat/Poste

- **Filtre des rôles éligibles** : un rôle peut être restreint à certains départements ou localisations
- **Limite des dates** : un rôle affecté ne peut avoir de durée plus large que le contrat lui-même
- **Scopes additionnels** : la région, le centre de coûts d'un contrat peut servir de critère pour des rôles scopés
- **Audit du contexte** : chaque affectation capture un snapshot du contrat de la personne au moment de l'assignation

### 4.3 Synchronisation avec systèmes source

- **RH système** : topic `arc.sync.rh` fournit les changements de poste/contrat
- **Mise à jour incrémentale** : chaque changement (début/fin poste, transfert…) est détecté et reflété
- **Réévaluation des rôles** : à chaque changement de contrat, les rôles affectés sont réévalués (cf. §10.2)

---

## 5. Modèle de rôles

### 5.1 Qu'est-ce qu'un rôle ?

Un **rôle** est une **unité logique de droits d'accès** qui :
- Encapsule un ensemble de ressources de sécurité (groupes AD, rôles applicatifs…)
- Est affectable à des identités selon des critères (profil, poste, localisation)
- Peut nécessiter une validation avant d'être déployée
- Est versionnée et auditée

### 5.2 Structure d'un rôle

| Champ | Type | Obligatoire | Description |
|-------|------|-------------|-------------|
| `id` | UUID | ✓ | Identifiant du rôle |
| `name` | String | ✓ | Nom fonctionnel (e.g., "Finance Manager") |
| `slug` | String | ✓ | Identifiant unique URL-safe (auto-généré) |
| `description` | String | Opt | Description détaillée du rôle et de ses droits |
| `owner` | UUID | ✓ | Propriétaire métier (Identity ID) |
| `status` | Enum | ✓ | `draft` / `active` / `archived` / `deprecated` |
| `sensitivtyLevel` | Enum | ✓ | `low` / `medium` / `high` / `critical` |
| `validationLevels` | Int | ✓ | Nombre de niveaux de validation requis (0-3) |
| `createdAt` | DateTime | ✓ | |
| `createdBy` | UUID | ✓ | |
| `updatedAt` | DateTime | ✓ | |
| `metadata` | Map | Opt | Champs additionnels (riskLevel, businessJustification…) |
| `version` | String | ✓ | Versioning sémantique (e.g., "1.2.3") |

### 5.3 Qualifications de rôles (Entitlement Mappings)

Chaque rôle contient un ensemble de **qualifications** qui mappent vers des ressources de sécurité réelles.

Cf. section 6.

### 5.4 Restrictions d'éligibilité

Un rôle peut être restreint :
- **Par département** : liste de départements autorisés
- **Par localisation** : zones géographiques éligibles
- **Par type d'identité** : personne vs. service vs. machine
- **Par critère custom** : attributs libres dans le metadata

### 5.5 Cycle de vie d'un rôle

```
[Draft] → [Review] → [Active] ⟷ [Archived] → [Deprecated]
```

- **Draft** : création, modifications en cours
- **Review** : en attente de validation (selon validationLevels)
- **Active** : peut être affecté à des identités
- **Archived** : plus aucune nouvelle affectation, maintient les assignations existantes
- **Deprecated** : signale la fin de vie, peut forcer révocation

---

## 6. Mappings entre rôles et ressources de sécurité

### 6.1 Définition : Entitlement

Un **Entitlement** est la manifestation concrète d'un droit dans un système cible.

| Champ | Type | Description |
|-------|------|-------------|
| `id` | UUID | Identifiant de l'entitlement |
| `sourceSystem` | String | Système cible (`activedirectory`, `app-a`, `aws-iam`, `k8s`) |
| `type` | Enum | `security-group` / `app-role` / `iam-role` / `permission-set` / `other` |
| `externalId` | String | Identifiant réel dans le système (SID groupe, ARN…) |
| `displayName` | String | Nom compréhensible |
| `description` | String | Justification du droit |

### 6.2 Mapping Rôle → Entitlements

Un rôle **single source** :

```json
{
  "roleId": "role-uuid-123",
  "name": "Finance Manager",
  "entitlements": [
    {
      "sourceSystem": "activedirectory",
      "type": "security-group",
      "externalId": "S-1-5-21-...-512",
      "displayName": "FIN-Manager-Group"
    }
  ]
}
```

Un rôle **multi-source** (exemple : accès simultané à AD + application cloud) :

```json
{
  "roleId": "role-uuid-456",
  "name": "Cloud Finance Analyst",
  "entitlements": [
    {
      "sourceSystem": "activedirectory",
      "type": "security-group",
      "externalId": "S-1-5-21-...-2048",
      "displayName": "FIN-CloudAccess"
    },
    {
      "sourceSystem": "aws-iam",
      "type": "iam-role",
      "externalId": "arn:aws:iam::123456789012:role/finance-analyst",
      "displayName": "finance-analyst"
    },
    {
      "sourceSystem": "app-salesforce",
      "type": "permission-set",
      "externalId": "perm-set-fa-001",
      "displayName": "Finance Analyst Permission Set"
    }
  ]
}
```

### 6.3 Gestion des ressources de sécurité (Entitlements Registry)

La plateforme maintient un **registre centralisé des entitlements** disponibles dans chaque système source, alimenté par le **topic `arc.sync.entitlement`** (produit par arc-consolidator) :

| Topic | Entitlements consommés | Système | Champ `system` |
|-------|----------------------|--------|----------------|
| `arc.sync.entitlement` | Groupes de sécurité, groupes de distribution, profils applicatifs, rôles IAM, ClusterRoles… | Tous (AD, apps, AWS, K8s, etc.) | Identifie le système via `entitlement.system` (e.g., `ad://corp.example.com`) |

**Chaque entitlement stocké inclut :**
- Timestamp de découverte
- Propriétaire dans le système source
- Description/documentation
- État (active/archived/unknown)
- Mappages vers rôles (reverse index)

### 6.4 Versionning des mappings

Quand un entitlement est modifié ou retiré d'un rôle :

1. **Snapshot du mapping** : version N du rôle est créée
2. **Historique** : toutes les versions du rôle sont conservées
3. **Affectations existantes** : continuent avec le mapping qu'elles avaient
4. **Nouvelles affectations** : utilisent le nouveau mapping

---

## 7. Système d'authentification adaptable

### 7.1 Exigence multi-tenant et flexibilité client

Chaque **client/tenant** peut avoir un schéma d'authentification différent :
- Entreprise A : SAML + LDAP interne
- Entreprise B : OAuth2 / SSO propriétaire
- Entreprise C : Local (username/password, pour PoC)

### 7.2 Architecture d'authentification

```
┌─────────────────────────────────────┐
│      API Gateway / Load Balancer    │
└────────────────┬────────────────────┘
                 │
         ┌───────▼────────┐
         │ Auth Middleware│
         │ (Détecte tenant)
         └───────┬────────┘
                 │
     ┌───────────┴──────────────┐
     │                          │
     ▼                          ▼
┌──────────────┐        ┌──────────────┐
│ Local Auth   │        │ External Auth│
│ (Username/   │        │ (SAML, OAuth2│
│  Password)   │        │  OIDC, LDAP) │
└──────────────┘        └──────────────┘
     │                          │
     └───────────┬──────────────┘
                 │
           ┌─────▼──────┐
           │ JWT Token  │
           │ Generation │
           └─────┬──────┘
                 │
         ┌───────▼──────────┐
         │ Session + Perms  │
         │ (Redis Cache)    │
         └──────────────────┘
```

### 7.3 Configuration par tenant

Chaque tenant définit dans Config Service :

```json
{
  "tenantId": "client-a",
  "authentication": {
    "provider": "saml",
    "saml": {
      "entryPoint": "https://sso.client-a.com/sso",
      "issuer": "urn:client-a:sso",
      "cert": "<cert-pem>"
    },
    "sessionTTL": 3600,
    "mfaRequired": true
  }
}
```

### 7.4 Prise en charge des providers

| Provider | Format | Notes |
|----------|--------|-------|
| **Local** | Username / Password | Hash bcrypt, salt généré |
| **SAML 2.0** | Assertions XML | Avec metadata XML |
| **OAuth2** | Authorization Code Flow | Tokens JWT/Opaque |
| **OIDC** | OpenID Connect | UserInfo, Claims |
| **LDAP** | Bind + User lookup | DN pattern, filters |
| **Custom** | Webhook | POST vers endpoint client, réponse JSON |

### 7.5 Mapping des attributs

Après authentification, certains attributs doivent être mappés vers l'Identity :

```json
{
  "tenantId": "client-a",
  "attributeMapping": {
    "saml.NameID": "externalId",
    "saml.mail": "email",
    "saml.department": "metadata.department",
    "saml.custom:identificationKey": "identificationKey"
  }
}
```

---

## 8. Profils et autorisations d'accès

### 8.1 Profils d'application

Chaque utilisateur connecté a un ou plusieurs **profils** dans la plateforme, qui définissent ses permissions.

| Profil | Description | Actions primaires |
|--------|-------------|------------------|
| **Admin** | Administrateur système plateforme | Toutes les actions, gestion tenants |
| **Gestionnaire d'accès** (Access Manager) | Gestionnaire des rôles et affectations | Créer rôles, affecter, valider (si autorisé) |
| **Auditeur** | Audit et conformité | Lecture seule, rapports, détection drift |
| **Responsable métier** (Business Owner) | Propriétaire d'un domaine fonctionnel | Gérer les rôles dans son domaine, valider affectations |
| **Valideur de rôle** (Role Approver - 3 niveaux) | Approbateur de création/modification de rôles | Valider rôles selon niveau (cf. §14) |
| **Demandeur de droits** (Access Requester) | Personne demandant des droits | Créer demande d'accès (self-service ou pour tiers) |

### 8.2 Matrice des permissions

| Action | Admin | Gestionnaire | Auditeur | Responsable | Valideur (L1/L2/L3) | Demandeur |
|--------|-------|--------------|----------|------------|-----|----------|
| Voir identités | ✓ | ✓ | ✓ | ✓ (domaine) | ✓ (L2+) | Soi-même |
| Créer/modifier rôles | ✓ | ✓ | ✗ | ✓ (domaine) | ✗ | ✗ |
| Valider rôles (niveau) | ✓ | ✓ (L1) | ✗ | ✓ (L1) | ✓ (selon L) | ✗ |
| Affecter rôles manuellement | ✓ | ✓ | ✗ | ✓ (domaine) | ✗ | ✗ |
| Demander droits | ✓ | ✓ | ✗ | ✓ | ✓ | ✓ |
| Approuver demandes | ✓ | ✓ | ✗ | ✓ (domaine) | ✓ (L2+) | ✗ |
| Annuler affectations | ✓ | ✓ | ✗ | ✓ (domaine) | ✗ | ✗ |
| Voir rapports audit | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ |
| Gérer configurations | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |

### 8.3 Scoping des permissions

Les responsables métier et gestionnaires peuvent être scopes à des domaines spécifiques (département, équipe) :

```json
{
  "userId": "user-123",
  "profile": "Business Owner",
  "scope": {
    "type": "department",
    "value": "Finance",
    "displayName": "Département Finance"
  }
}
```

---

## 9. Récupération de l'image des ressources (T0)

### 9.1 Bootstrap : Image initiale

Au démarrage ou lors de l'onboarding d'une nouvelle source système, la plateforme doit **charger l'état complet** (snapshot T0) des ressources.

### 9.2 Sources d'alimentation

| Source | Topic | Contenu | Fréquence |
|--------|-------|---------|-----------|
| Active Directory | `arc.sync.activedirectory` | Groupes, utilisateurs, attributs | Temps réel (WEF) |
| Système RH | `arc.sync.rh` | Contrats, postes, attributs | Daily ou temps réel |
| Application A | `arc.sync.app-a` | Comptes applicatifs, profils | À chaque changement |
| AWS IAM | `arc.sync.aws-iam` | Rôles, utilisateurs, attachements | Polling ou event-driven |
| Azure Entra | `arc.sync.entra` | Groupes, utilisateurs, roles | Graph API polling |
| Kubernetes | `arc.sync.k8s` | ServiceAccounts, ClusterRoles, bindings | API server polling |

### 9.3 Processus d'ingestion initial

```
[Consumer thread] (Identity Service + Assignment Service)
    │
    ├─► Connecter aux 3 topics arc.sync.*
    │   - arc.sync.identity
    │   - arc.sync.entitlement
    │   - arc.sync.assignment
    │
    ├─► Consommer tous les messages (offset = 0) de chaque topic
    │   Messages déjà normalisés au modèle IAM abstrait par arc-consolidator
    │
    ├─► Pour chaque message :
    │   - Extraire le champ `system` (détermine source ET cible)
    │   - Stocker dans la base de données (Identity, Entitlements, Assignments)
    │   - Indexer pour requêtes futures
    │   - Associer aux rôles existants (reverse mapping)
    │
    └─► À fin du bootstrap :
        - Marquer l'image T0 comme "complète" pour chaque système
        - Déclencher réévaluation des règles d'affectation automatiques
        - Lancer détection drift initial (expected vs. actual)

```

### 9.4 Entitlements Registry

Structure persistée (construite à partir des messages `arc.sync.entitlement`) :

```json
{
  "entitlementId": "e7d3a021-...",
  "system": "ad://corp.example.com",
  "externalId": "S-1-5-21-...-512",
  "displayName": "Domain Admins",
  "name": "Domain Admins",
  "type": "security-group",
  "sensitivityLevel": "CRITICAL",
  "discoveredAt": "2026-05-08T10:30:00Z",
  "owner": null,
  "state": "active",
  "lastSyncedAt": "2026-05-08T10:35:12Z",
  "mappedToRoles": ["role-uuid-1", "role-uuid-2"],
  "metadata": { ... }
}
```

**Note** : Les données proviennent directement du topic `arc.sync.entitlement`, déjà normalisées par arc-consolidator. Le champ `system` permet d'identifier à la fois la source et la cible (même système).

---

## 10. Affectations de rôles : manuelles et automatiques

### 10.1 Affectation manuelle

**Acteur** : Gestionnaire d'accès, responsable métier

**Flux** :

1. Gestionnaire sélectionne une identité
2. Gestionnaire sélectionne un rôle (filtré par éligibilité du rôle + contexte identité)
3. Peut définir une date de début et une date de fin (optionnelles)
4. Les dates proposées par défaut sont les dates du contrat/poste courant
5. Les dates de fin peuvent être plus restrictives que le contrat, jamais plus larges
6. Validation en fonction du `validationLevels` du rôle (cf. §14)
7. Ordre créé dans `arc.provisioning` avec état `pending`

### 10.2 Affectation automatique

**Fondement** : Règles d'affectation basées sur les attributs de l'Identity et son contexte.

#### 10.2.1 Création d'une règle

Une règle est définie par :

```json
{
  "ruleId": "uuid",
  "name": "Finance Managers - Global Group",
  "description": "Affecte automatiquement le rôle Finance Manager à tout responsable du département Finance",
  "roleId": "role-uuid-finance-manager",
  "tenantId": "client-a",
  "enabled": true,
  "criteria": {
    "logic": "AND",
    "conditions": [
      {
        "field": "contract.department",
        "operator": "equals",
        "value": "Finance"
      },
      {
        "field": "identity.metadata.jobFunction",
        "operator": "matches",
        "value": "^Manager.*"
      },
      {
        "field": "identity.status",
        "operator": "equals",
        "value": "active"
      }
    ]
  },
  "assignmentDefaults": {
    "startDate": "contractStart",
    "endDate": "contractEnd",
    "scope": null
  },
  "createdAt": "2026-05-01T12:00:00Z",
  "createdBy": "admin-uuid"
}
```

#### 10.2.2 Évaluation des règles

Chaque règle est réévaluée dans les scénarios :

- **À la création/modification d'une identité** : évaluation de toutes les règles
- **À chaque changement de contrat/poste** : réévaluation
- **À chaque changement d'identité (attributs)** : réévaluation
- **À la création/modification d'une règle** : réévaluation contre toutes les identités éligibles

#### 10.2.3 Résultat de l'évaluation

Si la condition est vraie :

1. Une affectation est **créée automatiquement** (state = `pending`)
2. Un ordre d'assignation est généré et envoyé à `arc-publisher` via API (`POST /jobs`)
3. Audit tracé avec `ruleId` comme source
4. Notification au responsable métier

Si la condition devient fausse (rétroactivement) :

1. L'affectation existante est **révoquée** (state = `revoked`)
2. Un ordre de retrait est envoyé à `arc-publisher` via API (`POST /jobs`)
3. Audit tracé

### 10.3 Cycle de vie d'une affectation

```
[Création manuelle/auto]
           │
           ▼
      [Pending] ◄─── peut être annulée ici
           │
           ├─► Validation multi-niveaux (si requis)
           │
           ▼
      [Approved] ◄─── peut être révoquée manuellement
           │
         ├─► Ordre créé dans arc-publisher (API POST /jobs)
         │   (avec startDate/endDate ou date d'effet métier)
           │
           ▼
      [Active] ◄─── Droits effectifs dans les systèmes cibles
           │
           ├─► Peut être annulée jusqu'au retrait effectif
           │
           ├─► À date de fin (endDate) ou révocation manuelle
           │
           ▼
      [Revoked] ◄─── Ordre de suppression envoyé
           │
           ▼
      [Ended]
```

### 10.4 Vérifications d'éligibilité

Avant de créer une affectation, le système vérifie :

- ✓ Identité existe et est active (ou status permettant l'affectation)
- ✓ Rôle existe et est actif
- ✓ Rôle est éligible pour cette identité (restrictions du rôle)
- ✓ Contrat/poste est actif à la date d'affectation
- ✓ Pas de rôle conflictuel ou dupliqué (configurable)
- ✓ Permissions de l'utilisateur qui crée l'affectation
- ✓ Audit trail cohérent

---

## 11. Ordres d'assignation et cycle de vie

### 11.1 Structure de l'ordre (Job)

Un **Job** (ou ordre d'assignation) représente l'intention de provisionner ou révoquer un droit dans un système cible.

| Champ | Type | Description |
|-------|------|-------------|
| `jobId` | UUID | Identifiant unique généré par la plateforme |
| `assignmentId` | UUID | Lien vers l'Assignment |
| `sourceSystem` | String | Système destination (`activedirectory`, `app-a`, `aws-iam`…) |
| `operationType` | Enum | `add` / `remove` / `modify` |
| `entitlementId` | UUID | Entitlement concerné |
| `entitlementExternalId` | String | Identifiant externe dans le système cible |
| `identityExternalId` | String | Identifiant de l'identity dans le système cible |
| `startDate` | DateTime | Date de début de l'affectation |
| `endDate` | DateTime | Date de fin de l'affectation (optionnelle) |
| `state` | Enum | `pending` / `queued` / `sent` / `failed` / `revoked` / `completed` |
| `createdAt` | DateTime | Horodatage création |
| `createdBy` | UUID | Qui a créé le job |
| `scheduledFor` | DateTime | Date/heure d'exécution planifiée |
| `executedAt` | DateTime | Horodatage réelle exécution (quand arc-publisher a traité) |
| `executionResult` | Enum | `success` / `failure` / `partial` / `pending` |
| `errorMessage` | String | Message d'erreur si `executionResult = failure` |
| `metadata` | Map | Contexte additionnel (auditTrail, justification…) |

### 11.2 Flux de l'ordre

```
[Creation]
  │
  ├─► État initial: pending
  │
  ├─► Validation multi-niveaux si requis (cf. §14)
  │
  ├─► Assignment Service appelle arc-publisher (POST /jobs)
  │   Payload: ordre + dates d'effet (now, demain, arrivée, mutation...)
  │
  ├─► arc-publisher persiste le job en PostgreSQL
  │
  ├─► arc-publisher recalcule périodiquement les jobs pending
  │   (ex: toutes les secondes)
  │
  ├─► Quand la date d'exécution est atteinte:
  │   arc-publisher publie dans arc.provisioning.*
  │
  ├─► Les agents consomment en temps réel et exécutent
  │   (sans logique de temporalité)
  │
  ├─► Retour d'exécution vers IAM (succès/échec)
  │
  ├─► État final: completed ou failed
  │
  └─► Audit complet enregistré
```

### 11.3 Cas de cycle de vie

#### 11.3.1 Ordre normal

```
pending → queued (arc-publisher) → sent (arc.provisioning.*) → completed (success)
```

#### 11.3.2 Ordre avec date future

```
pending → queued (arc-publisher) → [at startDate] → sent → completed
```

#### 11.3.3 Annulation avant envoi

```
pending → cancelled (annulation possible tant que state ≠ sent)
```

#### 11.3.4 Tentative d'annulation après envoi

```
sent → job déjà publié dans arc-publisher → tentative de compensation (remove job)
```

Si arc-collector rapporte que l'opération est exécutée (state = completed), l'annulation n'est plus possible et génère une révocation inverse (remove job).

#### 11.3.5 Révocation avec date de fin

```
active → [at endDate] → revoke order created → sent → completed (remove)
```

### 11.4 Publication et consommation

**Intégration Job (système de scheduling)** :
- `Assignment Service` appelle `arc-publisher` via API `POST /jobs`
- `arc-publisher` stocke le job en PostgreSQL et gère la temporalité
- `arc-publisher` publie ensuite dans `arc.provisioning.*` quand l'ordre est exécutable
- Les agents consomment `arc.provisioning.*` en temps réel

**Topics opérationnels** :
- `arc.provisioning.*` — ordres prêts à exécuter, publiés par `arc-publisher`

**Format de message** (CloudEvents) :

```json
{
  "specversion": "1.0",
  "id": "job-uuid-xxx",
  "source": "instantaccessprovider/assignment-service",
  "type": "com.instantaccess.job.created",
  "time": "2026-05-08T14:30:00.000Z",
  "datacontenttype": "application/json",
  
  "data": {
    "job": {
      "jobId": "job-uuid-xxx",
      "assignmentId": "assignment-uuid",
      "sourceSystem": "activedirectory",
      "operationType": "add",
      "entitlementExternalId": "S-1-5-21-...-512",
      "identityExternalId": "S-1-5-21-...-1001",
      "startDate": "2026-05-08T00:00:00Z",
      "endDate": "2026-12-31T23:59:59Z",
      "scheduledFor": "2026-05-08T15:00:00Z",
      "createdBy": "user-uuid-admin",
      "metadata": {
        "assignmentContext": "manual",
        "justification": "Promotion responsable IT"
      }
    }
  }
}
```

**Retour d'état d'exécution vers IAM** (exemple de message) :

```json
{
  "specversion": "1.0",
  "id": "job-result-xxx",
  "source": "arc-publisher",
  "type": "com.instantaccess.job.completed",
  "time": "2026-05-08T15:02:30.000Z",
  
  "data": {
    "jobId": "job-uuid-xxx",
    "state": "completed",
    "executionResult": "success",
    "executedAt": "2026-05-08T15:02:25.000Z"
  }
}
```

---

## 12. Gestion des clés d'identification

### 12.1 Concept fondamental

La **clé d'identification** (Identification Key) est un **identifiant unique et stable** par personne, généré ou fourni une fois, qui sert de socle pour toutes les règles métier de la plateforme.

**Caractéristiques** :
- **Unique** par tenant et par personne
- **Stable** : ne change jamais au cours de la vie de la personne
- **Obfusquée** : peut être un UUID, un séquentiel, un hash, selon la politique du client
- **Routière** : la clé et les règles de mappages permettent de créer des comptes dans les systèmes sources

### 12.2 Stratégie de génération

#### 12.2.1 Auto-générée (par défaut)

À chaque création d'identité, la plateforme génère une clé unique :

```
Format: [PREFIX]_[RANDOM_HEX]
Exemple: IAPID_a7e9c2f1b3d4
```

Le client peut configurer le format via regex/template.

#### 12.2.2 Fournie (migration)

Lors de l'import depuis un système externe :

```
L'administrateur fournit les clés pour les identités existantes.
La clé est associée à l'identité migr et marquée comme "imported".
Si doublon, erreur bloquante.
```

### 12.3 Règles d'appartenance (Account Mapping Rules)

Une fois la clé générée/fournie, le **client peut définir des règles de transformation** pour mapper la clé vers des comptes réels dans ses systèmes sources.

**Exemple 1 : AD, format simple (5 chars)**

```
Client définit:
  - Clé: "A7E9C" (5 caractères alphanumériques)
  - Règle AD: "V" + clé = "VA7E9C"
  
Résultat: 
  - SAM Account Name: VA7E9C
  - UPN: va7e9c@corp.local
```

**Exemple 2 : Format complexe (regex)**

```
Client définit:
  - Clé: "EMP-2025-00742"
  - Règle AD: "^EMP-(\d+)-(\d+)$" → "EMP\2_\1"
  
Résultat:
  - SAM Account Name: EMP742_2025
```

**Exemple 3 : Substitution multi-attribut**

```
Client définit:
  - Clé: "JOHN.D.2025"
  - Règle pour application A:
      Format: "[FIRSTNAME].[LASTNAME].[YEAR]"
      Mapping: Clé → split and format
  
Résultat:
  - Application A login: john.d.2025
```

### 12.4 Multi-clés (jusqu'à 10 par personne)

Un client peut autoriser **plusieurs clés d'identification par personne** (jusqu'à 10 par défaut) pour :

- **Transitions** : migrer progressivement sans casser les accès existants
- **Multi-systèmes** : une clé par système source intégré
- **Contextes différents** : clés différentes pour contrats différents

**Structurre** :

```json
{
  "identityId": "person-uuid",
  "identificationKeys": [
    {
      "keyId": "key-1",
      "value": "EMP-2025-00742",
      "sourceSystem": "activedirectory",
      "isPrimary": true,
      "createdAt": "2026-01-15T10:00:00Z",
      "validUntil": null
    },
    {
      "keyId": "key-2",
      "value": "OLD-EMP-1234",
      "sourceSystem": "legacy-system",
      "isPrimary": false,
      "createdAt": "2025-06-01T10:00:00Z",
      "validUntil": "2026-12-31T23:59:59Z"
    }
  ]
}
```

### 12.5 Utilisation des clés dans les ordres

Quand un Job est créé pour provisionner un droit :

1. Récupérer la clé d'identification de l'identité
2. Appliquer les règles d'appartenance du système cible
3. Générer le SAM Account Name, UPN, login applicatif, etc.
4. Inclure dans le payload du Job

---

## 13. Gestion des écarts (Compliance Drift)

### 13.1 Définition : Drift

Un **drift** (écart de conformité) est une divergence entre :
- **État souhaité** : ce que les rôles et affectations devraient produire
- **État réel** : ce qui existe vraiment dans les systèmes sources

### 13.2 Types de drifts détectables

#### 13.2.1 Drift positif (Unauthorized Access)

```
L'identité X a l'entitlement Y, mais :
- Aucun rôle affecté ne devrait donner Y
- Aucune règle d'affectation ne devrait produire Y
```

**Causes possibles** :
- Affectation manuelle dans le système source (hors plateforme)
- Erreur ou manipulation
- Héritage involontaire de groupe

#### 13.2.2 Drift négatif (Missing Access)

```
L'identité X devrait avoir l'entitlement Y (via un rôle affecté), mais :
- Y n'existe pas dans le système source
- L'assignment n'a pas été appliqué
```

**Causes possibles** :
- Ordre bloqué ou échoué chez arc-publisher
- Entitlement supprimé ou archivé du côté source
- Délai de propagation (AD replication lag, application delay…)

#### 13.2.3 Drift de révocation (Orphaned Access)

```
L'identité X avait l'entitlement Y (affectation expirée/révoquée), mais :
- Y existe toujours dans le système source
```

**Causes possibles** :
- Retrait manqué ou échoué
- Erreur du système cible

### 13.3 Architecture de détection Drift

```
┌─────────────────────────────────────┐
│  Arc.sync topics (état réel T_n)    │
└────────────────┬────────────────────┘
                 │
         ┌───────▼────────┐
         │ Drift Detection│
         │   Service      │
         └───────┬────────┘
                 │
      ┌──────────┴──────────┐
      │                     │
      ▼                     ▼
┌──────────────┐    ┌─────────────────┐
│ Expected     │    │ Actual from     │
│ from IAM DB  │    │ arc.sync topics │
│ (rôles +     │    │                 │
│ assignments) │    │                 │
└──────────────┘    └─────────────────┘
      │                     │
      └──────────┬──────────┘
                 │
        ┌────────▼────────┐
        │ Diff Algorithm  │
        │ (3-way merge)   │
        └────────┬────────┘
                 │
         ┌───────▼───────┐
         │ Drift Report  │
         │ + Alerts      │
         └───────────────┘
```

### 13.4 Algorithme de détection (3-way merge)

Pour chaque (Identity, Entitlement) paire :

```
expected = ∪ (Entitlements from Active Assignments + Active Rules)
actual   = Entitlements from arc.sync
delta    = actual △ expected  (XOR logique)

Si delta non-vide:
  - Si entitlement ∈ actual et ∉ expected → DRIFT_POSITIVE (unauthorized)
  - Si entitlement ∉ actual et ∈ expected → DRIFT_NEGATIVE (missing)
```

### 13.5 Rapport et escalade

Chaque drift détecté génère :

```json
{
  "driftId": "uuid",
  "detectedAt": "2026-05-08T14:30:00Z",
  "identity": { "id": "...", "displayName": "Jean Dupont" },
  "entitlement": { "id": "...", "externalId": "..." },
  "sourceSystem": "activedirectory",
  "driftType": "DRIFT_POSITIVE",
  "severity": "HIGH",
  "expectedState": "absent",
  "actualState": "present",
  "possibleCauses": [
    "Manual provisioning outside IAM",
    "Group nesting inheritance"
  ],
  "suggestedActions": [
    "Remove entitlement from identity",
    "Investigate source system",
    "Create rule to reflect reality"
  ],
  "assignedTo": "auditeur-uuid",
  "status": "open"
}
```

**Actions possibles** :
- **Ignore** : marquer comme connu/acceptable
- **Remediate Automatic** : déclencher retrait ou ajout automatique
- **Investigate** : marqué pour audit manuel
- **Reject** : ignorer le drift (ne pas corriger)
- **Create Rule** : convertir le drift en règle d'affectation légitime

### 13.6 Alertes et notifications

- **Dashboard Drift** : vue temps réel des drifts actifs
- **Reports** : hebdomadaires/mensuels, par système source, par sévérité
- **Escalades** : les drifts critiques non-résolus génèrent alertes

---

## 14. Validation multi-niveaux des rôles

### 14.1 Concept

Chaque rôle peut nécessiter une **validation (approbation) multi-niveaux** avant d'être déployable.

Le rôle définit son `validationLevels` (0-3) :

| Niveau | Étapes | Utilisateurs |
|--------|--------|--------------|
| **0** | Pas de validation | Direct → Active |
| **1** | 1 approbation | Valideur L1 ou Gestionnaire |
| **2** | 2 approbations successives | Valideur L1 → Valideur L2 |
| **3** | 3 approbations successives | Valideur L1 → Valideur L2 → Valideur L3 |

### 14.2 État du rôle selon validations

```
[Draft] 
  │
  ├─► À validation L1
  │   ├─► Approuvé L1 → À validation L2 (si niveau 2-3)
  │   │   ├─► Approuvé L2 → À validation L3 (si niveau 3)
  │   │   │   ├─► Approuvé L3 → Active
  │   │   │   └─► Rejeté L3 → Draft
  │   │   └─► Rejeté L2 → Draft
  │   └─► Rejeté L1 → Draft
  │
  └─► À validation L1 → [repeat]
```

### 14.3 Flux de validation

#### 14.3.1 Création d'un rôle

1. Gestionnaire crée un rôle brouillon (Draft)
2. Clique "Soumettre pour validation"
3. État → "À validation L1"
4. Notifications envoyées aux Valideurs L1 du tenant

#### 14.3.2 Approbation L1

Valideur L1 reçoit la demande, revue le rôle :

- **Détails du rôle** (nom, description, entitlements)
- **Impact** (nombre identités éligibles, sensibilité)
- **Justification métier** fournie par créateur

Approbation :
- ✓ Approuver → État "À validation L2" (si niveau 2+) ou "Active" (si niveau 1)
- ✗ Rejeter + commentaire → État "Draft"
- ⏸ Demander modifications

#### 14.3.3 Approbations L2 et L3

Processus identique, escalade successive.

### 14.4 Audit des validations

Chaque approbation/rejet est tracée :

```json
{
  "roleId": "role-uuid",
  "validationHistory": [
    {
      "level": 1,
      "approver": "valideur-l1-uuid",
      "approverName": "Marie Bernard",
      "decision": "approved",
      "comment": "Rôle bien documenté, risque faible",
      "approvedAt": "2026-05-08T10:15:00Z"
    },
    {
      "level": 2,
      "approver": "valideur-l2-uuid",
      "approverName": "Jean Pelletier",
      "decision": "rejected",
      "comment": "Nécessite clarification sur scope geographic",
      "rejectedAt": "2026-05-08T11:30:00Z"
    }
  ]
}
```

### 14.5 Modification de rôle et re-validation

Si un rôle actif est modifié (ajout/suppression d'entitlements, changement de restriction d'éligibilité) :

- **Modification majeure** (entitlements changent) → Re-validation depuis L1
- **Modification mineure** (description, métadata) → Pas de re-validation

---

## 15. Roadmap V2

### 15.1 Gestion des risques

**Objectif** : quantifier et monitorer le risque d'accès

**Fonctionnalités** :

- **Risk Scoring** : score de risque par rôle, basé sur sensibilité + nombre assignés
- **Risk Thresholds** : alertes si un rôle "sensible" dépasse N assignations
- **Segregation of Duties (SoD)** : détecter et prévenir combinaisons conflictuelles de rôles
  - Exemple : une personne ne peut pas avoir à la fois "Valideur Finance" et "Valideur de Paiement"
- **Risk Dashboard** : vue d'ensemble du risque de l'organisation

### 15.2 Campagnes de recertification

**Objectif** : audit périodique des droits d'accès par responsables métier

**Fonctionnalités** :

- **Campagne Template** : configurer campagnes (fréquence, scope, valideurs)
- **Génération Campagne** : créer instances et notifier responsables
- **Review Interface** : responsables review chaque assignation
  - ✓ Confirmer → Approuver continuation
  - ✗ Révoquer → Créer ordre de retrait
  - ❓ Question → Demander clarification
- **Audit Trail** : tracer qui a certifié quoi, quand
- **Non-Completion Escalation** : rappels automatiques, escalade si délai dépassé

### 15.3 Prise en charge des délégations temporaires

**Objectif** : "Mon manager est en vacances, je dois prendre ses décisions"

**Fonctionnalités** :

- **Delegation Rules** : créer délégation temporaire de profil/permissions
- **Audit** : tracer que X a délégué à Y pour période [T1, T2]
- **Auto-Revocation** : revoquer automatiquement à fin de période

### 15.4 Intégrations avancées

- **Single Sign-On (SSO) complet** : plus de formulaire login, juste redirection
- **Provisioning reverse** : si arc-publisher crée un compte, la plateforme le détecte et met à jour
- **Webhooks** : clients peuvent créer webhooks pour événements IAM
- **API REST complète** : toutes les opérations accessibles via API

### 15.5 Conformité réglementaire

- **SOX Compliance** : rapports SOX, séparation des fonctions
- **GDPR Compliance** : droit à l'oubli, export données personnelles
- **ISO 27001** : audit logs, configurations de sécurité

### 15.6 Optimisations performance

- **Caching distribué** : augmenter cache Redis pour rôles/entitlements fréquents
- **Batch Operations** : affectar rôles à 100+ identités en une opération
- **Advanced Reporting** : rapports SQL complexes, export Excel/PDF

---

## Appendice A : Glossaire

| Terme | Définition |
|-------|-----------|
| **Affectation (Assignment)** | Lien effectif entre une Identity et un Entitlement à un instant donné |
| **Clé d'Identification** | Identifiant unique et stable par personne, socle des règles métier |
| **Drift** | Divergence entre état souhaité (IAM) et état réel (systèmes sources) |
| **Entitlement** | Droit d'accès concret dans un système source (groupe AD, rôle IAM…) |
| **Identity** | Abstraction d'une personne/compte/service capable d'avoir des droits |
| **Job** | Ordre d'assignation à envoyer à arc-provisioning et arc-publisher |
| **Rôle** | Ensemble logique de droits (entitlements) affectable à des identities |
| **Tenant** | Client/organisation avec configuration isolée (multi-tenancy) |
| **T0** | Image initiale (snapshot) de l'état d'un système à onboarding |

---

## Appendice B : Questions d'implémentation ouvertes

1. **Pagination des rôles affectés** : à l'écran "Rôles de Jean", comment paginer si 500+ rôles ?
2. **Durée de rétention audit** : conserver audit complet pendant combien de temps ?
3. **Versioning des règles d'affectation** : faut-il tracker les versions des règles comme les rôles ?
4. **Timezone handling** : comment gérer les dates de contrat/assignation cross-timezone ?
5. **Bulk Import** : import de 10k+ identités. Format fichier ? Validation ? Rollback ?

---

**Version:** 1.0  
**Dernière mise à jour:** 8 Mai 2026  
**Propriétaire:** InstantAccessProvider Core Team  
**Statut:** ✓ Approuvé pour V1
