# 14 — Comptes, identités et console web (`product-manager`, `identity-manager`, `arc-console`)

> **Statut : implémenté et validé en démonstration** (`demo/docker-compose.yml`). Ce document décrit la gestion des comptes rattachés aux produits et aux identités humaines, ainsi que la console web qui remplace `arc-gateway` et `arc-gateway-frontend-node`.

## 1. Objectifs

- Gérer les **profils** (équivalents de groupes) d'un produit.
- Gérer les **comptes non utilisateurs** (comptes de service) rattachés à un **produit** : service `product-manager`.
- Gérer les **identités humaines** et leurs **comptes utilisateurs** : service distinct `identity-manager`.
- Définir les **types de compte** par la configuration du déploiement, sans modifier le code ni le schéma SQL.
- Alimenter les comptes de deux façons : **création par l'API ou l'interface** (avec job de provisioning) et **découverte** à partir de l'annuaire collecté.

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

## 3. Alimentation des comptes

```text
Annuaire --> agent collecteur --> iam.raw.* --> arc-consolidator --> arc.sync.identity
                                                                          |
                                      +-----------------------------------+
                                      v                                   v
                              product-manager                     identity-manager
                       (type NON_USER reconnu par motif)   (type USER reconnu par motif)

Console / API --POST /accounts--> product-manager | identity-manager --POST /jobs--> arc-publisher
```

- **Découverte** (`ARC_DISCOVERY_ENABLED=true`) : chaque événement de `arc.sync.identity` est comparé aux motifs des types. L'identifiant utilisé est le champ `name` (identifiant technique : `uid` LDAP, `sAMAccountName`), à défaut `displayName` lorsque `name` est un DN. Un compte reconnu est enregistré avec la source `DISCOVERED` ; s'il correspond à un produit ou à une identité existants, il y est corrélé, sinon il reste **non corrélé**. `POST /accounts/correlate` rejoue la corrélation (par exemple après la création du produit).
- **Création** : `POST /accounts` crée le compte et un job de provisioning auprès d'`arc-publisher` (source `API`).

## 4. Sécurité

`product-manager` et `identity-manager` valident les jetons d'`arc-auth` comme décrit au document 13 (RS256, JWKS, `aud=arc`, rôles `ARC_READER`, `ARC_PUBLISHER`, `ARC_ADMIN`). Ils appellent `arc-publisher` avec un **compte de service** membre de `arc-publishers`.

## 5. Console web (`arc-console`)

- Formulaire de connexion → `POST /token` d'`arc-auth` (relayé par le serveur de la console). Le jeton est conservé dans le `sessionStorage` du navigateur.
- Le serveur de la console sert l'interface et relaie, sans état et sans CORS, les appels `/api/pm/*` (`product-manager`) et `/api/im/*` (`identity-manager`) en transmettant l'en-tête `Authorization`.
- Les rôles du jeton ne servent qu'à afficher ou masquer les actions : **les API restent seules juges des droits**.
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
