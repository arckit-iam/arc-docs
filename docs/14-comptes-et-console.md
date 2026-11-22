# 14 — Comptes, identités et console web (`product-manager`, `identity-manager`, `arc-console`)

> **Statut : implémenté et validé en démonstration** (`demo/docker-compose.yml`). Ce document décrit la gestion des comptes rattachés aux produits et aux identités humaines, ainsi que la console web qui remplace `arc-gateway` et `arc-gateway-frontend-node`.

## 1. Objectifs

- Gérer les **profils** (équivalents de groupes) d'un produit.
- Gérer les **comptes non utilisateurs** (comptes de service) rattachés à un **produit** : service `product-manager`.
- Gérer les **identités humaines** et leurs **comptes utilisateurs** : service distinct `identity-manager`.
- Définir les **types de compte** par la configuration du déploiement, sans modifier le code ni le schéma SQL.
- Alimenter les comptes de deux façons : **création par l'API ou l'interface** (avec ordre de provisioning) et **découverte** à partir de l'annuaire collecté.

## 2. Types de compte

Les types sont déclarés dans la configuration (variables d'environnement, ou valeurs Helm) :

| Propriété | Rôle |
|---|---|
| `name` | Nom du type (`service-account`, `employee`, ...) |
| `kind` | `NON_USER` (`product-manager`) ou `USER` (`identity-manager`) |
| `pattern` | Expression régulière qui reconnaît un identifiant de compte ; le groupe nommé `product` (comptes non utilisateurs) ou `identity` (comptes utilisateurs) désigne le produit ou l'identité à corréler |
| `metadata` | Champs de métadonnées autorisés : `name`, `type` (`STRING`, ...), `required` |

Exemple de variables (`product-manager`) :

```text
ARC_ACCOUNTS_TYPES_0_NAME=service-account
ARC_ACCOUNTS_TYPES_0_KIND=NON_USER
ARC_ACCOUNTS_TYPES_0_PATTERN=svc-(?<product>[a-z0-9]+)-[a-z0-9]+
ARC_ACCOUNTS_TYPES_0_METADATA_0_NAME=owner
ARC_ACCOUNTS_TYPES_0_METADATA_0_TYPE=STRING
ARC_ACCOUNTS_TYPES_0_METADATA_0_REQUIRED=false
```

Les métadonnées sont stockées en **JSONB** dans PostgreSQL : ajouter un champ ne nécessite aucune migration.

### Comptes utilisateurs, matricules et contrats (`identity-manager`)

- Le **matricule** est généré à la création d'une identité : `I<DDDDDD>` (séquence PostgreSQL). Il n'est pas saisi.
- Deux types de comptes utilisateurs sont configurés : `standard` (`I<DDDDDD>`, même valeur que le matricule) et `admin` (`A<DDDDDD>`, corrélé à l'identité `I<DDDDDD>` de même numéro).
- Deux gabarits optionnels par type : `identityTemplate` (matricule déduit des groupes capturés, ex. `I{number}`) et `identifierTemplate` (identifiant généré si le compte est créé pour une identité sans identifiant, ex. `A{number}`).
- Une identité porte des **contrats** dont les types (prestataire, RH, stagiaire...) et les métadonnées sont configurables (`ARC_CONTRACTS_TYPES_<n>_*`).

### Périmètre des profils (TIER0, TIER1, TIER2)

Le périmètre est un attribut des **profils** (groupes) de `product-manager`, pas des comptes techniques. Il reprend le modèle d'administration en niveaux : TIER0 = infrastructure d'identité (annuaire, contrôleurs de domaine), TIER1 = serveurs et applications, TIER2 = postes et utilisateurs standard. Il est transmis à `arc-publisher` lors du provisioning du groupe. Un compte non utilisateur n'a qu'un type, un produit et des métadonnées.

## 3. Alimentation des comptes

```text
Annuaire --> agent collecteur --> iam.raw.* --> arc-consolidator --> arc.sync.identity
                                                                          |
                                      +-----------------------------------+
                                      v                                   v
                              product-manager                     identity-manager
                       (type NON_USER reconnu par motif)   (type USER reconnu par motif)

Console / API --POST /accounts--> product-manager | identity-manager --ordre--> arc.orders (Kafka) | POST /orders (API) --> arc-publisher
```

- **Découverte** (`ARC_DISCOVERY_ENABLED=true`) : chaque événement de `arc.sync.identity` est comparé aux motifs des types. L'identifiant utilisé est le champ `name` (identifiant technique : `uid` LDAP, `sAMAccountName`), à défaut `displayName` lorsque `name` est un DN. Un compte reconnu est enregistré avec la source `DISCOVERED` ; s'il correspond à un produit ou à une identité existants, il y est corrélé, sinon il reste **non corrélé**. `POST /accounts/correlate` rejoue la corrélation (par exemple après la création du produit).
- **Création** : `POST /accounts` crée le compte et un ordre de provisioning à destination d'`arc-publisher` (source `API`).

### Ordres, temporalité et annulation

Les managers ne connaissent pas l'annuaire cible : ils émettent des **ordres** métier (`CREATE` / `DELETE`, cible `IDENTITY` ou `ENTITLEMENT`) qui portent le **type de compte** (`accountType`) et, pour un profil, le **périmètre** (`scope`). L'agent associe lui-même chaque type de compte à sa branche d'annuaire (par exemple `standard` → `ou=Tier2`, `admin` → `ou=Tier0`), par sa configuration (`AD_ACCOUNT_TYPE_*_OU`, `ARC_AGENT_LDAP_ACCOUNT_TYPE_*_OU`). Un type que l'agent ne connaît pas est refusé.

**Canal d'émission** (`ARC_ORDERS_CHANNEL`) :

| Valeur | Comportement |
|---|---|
| `kafka` (défaut) | Le manager publie sur le topic `ARC_ORDERS_TOPIC` (`arc.orders`), clé = identifiant de l'ordre ; `arc-publisher` le consomme (`ARC_PUBLISHER_MODE=kafka` ou `both`). |
| `api` | Le manager appelle `POST /orders` (et `DELETE /orders/{id}`) d'`arc-publisher`, avec un jeton de compte de service. |

L'identifiant de l'ordre (UUID) est généré par le manager, ce qui permet de l'annuler quel que soit le canal.

**Temporalité** : un compte ou un profil porte une date de début et une date de fin facultatives (`startDate`, `endDate`, au format `yyyy-MM-dd`, fuseau `ARC_ORDERS_ZONE`, `UTC` par défaut).

- Ordre de création : `executeAt` = début (immédiat si le début est absent ou atteint).
- Ordre de suppression : `executeAt` = lendemain de la date de fin (le compte reste actif tout le jour de fin).
- `correlationId` : `account:<id>`, `account:<id>:end`, `account:<id>:delete`, `profile:<produit>:<profil>[:end|:delete]`.

**Annulation d'un ordre futur** (compte ou profil, `product-manager` et `identity-manager`) :

| Action | Effet |
|---|---|
| `PUT .../dates` | Remplace les dates ; les ordres en attente sont annulés puis recalculés. |
| `POST .../cancel-pending` | Annule l'ordre en attente : si la création n'a pas eu lieu, elle est annulée et l'entité supprimée ; sinon la fin programmée est annulée. `409` s'il n'y a rien à annuler. |
| `DELETE` | Supprimer une entité dont la création est encore en attente annule l'ordre ; si elle est active, un ordre `DELETE` immédiat est émis. |

Routes : `/accounts/{identifiant}/dates`, `/accounts/{identifiant}/cancel-pending`, `/products/{produit}/profiles/{profil}/dates`, `/products/{produit}/profiles/{profil}/cancel-pending`. Côté `arc-publisher`, annuler un ordre déjà exécuté est sans effet (`409` par l'API, ignoré par la file) : l'annulation ne vaut que tant que l'ordre est `PENDING`.

## 4. Sécurité

`product-manager` et `identity-manager` valident les jetons d'`arc-auth` comme décrit au document 13 (RS256, JWKS, `aud=arc`, rôles `ARC_READER`, `ARC_PUBLISHER`, `ARC_ADMIN`). Ils appellent `arc-publisher` avec un **compte de service** membre de `arc-publishers`.

## 5. Console web (`arc-console`)

- Formulaire de connexion → `POST /token` d'`arc-auth` (relayé par le serveur de la console). Le jeton est conservé dans le `sessionStorage` du navigateur.
- Le serveur de la console sert l'interface et relaie, sans état et sans CORS, les appels `/api/pm/*` (`product-manager`) et `/api/im/*` (`identity-manager`) en transmettant l'en-tête `Authorization`.
- Les rôles du jeton ne servent qu'à afficher ou masquer les actions : **les API restent seules juges des droits**.
- Comptes et profils affichent leur période de validité (début, fin) et leur statut (création planifiée, actif, expiré) ; les dates se modifient et l'ordre en attente s'annule depuis l'interface.
- En-têtes `Content-Security-Policy` stricts, aucune donnée injectée par `innerHTML`.

## 6. Abandon d'`arc-gateway` et `arc-gateway-frontend-node`

L'authentification Kerberos/SPNEGO de ces deux composants est abandonnée au profit de jetons JWT émis par `arc-auth` et d'une console dédiée. Les dépôts ne sont plus maintenus ; ils pourront être archivés.

## 7. Ports de démonstration

| Service | Port |
|---|---|
| `product-manager` | 8080 |
| `arc-publisher` | 8081 |
| `arc-auth` | 8082 |
| `identity-manager` | 8083 |
| `arc-console` | 3000 |
