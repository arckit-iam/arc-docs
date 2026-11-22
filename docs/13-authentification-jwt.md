# 13 — Authentification et jetons JWT (`arc-auth`)

> **Statut : implémenté et validé sur Apache DS.** `arc-auth` ([dépôt](https://github.com/arckit-iam/arc-auth)) émet les jetons ; `arc-publisher` et `product-manager` les exigent sur toute leur API, sauf `/actuator/health`. L'authentification est toujours imposée : il n'existe pas de mode « sécurité désactivée ». Les écarts avec la conception initiale sont signalés dans le texte.

## 1. Objectifs

| Objectif | Description |
|---|---|
| **Authentifier** | Vérifier l'identité d'un utilisateur ou d'un compte de service à partir d'un annuaire LDAP (Apache DS en démo, OpenLDAP ou autre en production). |
| **Émettre un jeton** | Délivrer un jeton **JWT signé** à durée de vie courte, portant l'identité et les rôles. |
| **Protéger les API** | Permettre à `arc-publisher` et `product-manager` de vérifier le jeton sans contacter `arc-auth` à chaque appel. |

Hors périmètre initial : fédération (OIDC complet, SAML), jetons de rafraîchissement, interface de connexion, authentification multifacteur (à traiter par l'annuaire ou un fournisseur d'identité en amont).

## 2. Architecture

`arc-auth` est un **service séparé**, sans état métier. Il ne stocke aucun mot de passe : la vérification est déléguée à l'annuaire par **bind LDAP**.

```mermaid
sequenceDiagram
    participant C as Client (PM, script, utilisateur)
    participant A as arc-auth
    participant L as Annuaire LDAP
    participant P as arc-publisher

    C->>A: POST /token (identifiant, mot de passe)
    A->>L: recherche (uid=identifiant) avec compte de service
    L-->>A: DN de l'utilisateur
    A->>L: bind (DN, mot de passe)
    L-->>A: succès ou échec
    A->>L: recherche des groupes de l'utilisateur
    L-->>A: groupes
    A-->>C: JWT signé RS256 (sub, roles, exp)
    C->>P: POST /orders (Authorization: Bearer JWT)
    P->>P: validation signature, exp, iss, aud, rôle
    Note over P,A: la clé publique est obtenue une fois via GET /.well-known/jwks.json
    P-->>C: 202 Accepted
```

## 3. API d'`arc-auth`

| Méthode et chemin | Description | Accès |
|---|---|---|
| `POST /token` | Corps JSON `{ "username": "...", "password": "..." }`. Retourne `200` avec `{ "access_token": "...", "token_type": "Bearer", "expires_in": 900 }` ou `401` (message générique identique pour utilisateur inconnu, mot de passe erroné ou utilisateur sans rôle ARC). `429` si la limitation de débit est atteinte, `503` si l'annuaire est injoignable. Un mot de passe vide n'est jamais transmis à l'annuaire. La réponse n'est pas mise en cache (`Cache-Control: no-store`). | Public |
| `GET /.well-known/jwks.json` | Clés publiques de signature (JWKS) | Public |
| `GET /actuator/health` | Santé du service (connexion LDAP) | Interne |

## 4. Authentification LDAP

Mécanisme : **bind authentication** (Spring Security LDAP, `BindAuthenticator`).

1. Connexion à l'annuaire avec un compte de service en lecture seule.
2. Recherche de l'utilisateur : `(uid={0})` sous `ARC_AUTH_LDAP_USER_SEARCH_BASE`.
3. Tentative de bind avec le DN trouvé et le mot de passe fourni. Le mot de passe n'est jamais comparé ni lu côté `arc-auth`.
4. Recherche des groupes (`groupOfNames`, attribut `member` = DN de l'utilisateur) sous `ARC_AUTH_LDAP_GROUP_SEARCH_BASE`.
5. Transformation des groupes en rôles (section 5).

Verrouillage de compte, politique de mot de passe et expiration relèvent de l'annuaire. `arc-auth` ajoute une limitation de débit par adresse source et par identifiant (réponse `429`) pour freiner les attaques par essais successifs.

## 5. Contenu du jeton

Signature **RS256** (clé asymétrique) : les services protégés n'ont besoin que de la clé publique.

En-tête : `{ "alg": "RS256", "typ": "JWT", "kid": "<identifiant de clé>" }`

Revendications :

| Claim | Valeur |
|---|---|
| `iss` | Émetteur (`ARC_AUTH_JWT_ISSUER`, ex. `https://arc-auth.example.com`) |
| `sub` | Identifiant de l'utilisateur (`uid`) |
| `aud` | Audience (`ARC_AUTH_JWT_AUDIENCE`, ex. `arc`) |
| `iat`, `nbf`, `exp` | Émission, début de validité, expiration (durée de vie par défaut : 15 minutes) |
| `jti` | Identifiant unique du jeton |
| `name` | Nom d'affichage (`cn`) |
| `roles` | Liste de rôles dérivés des groupes LDAP |

Table de correspondance groupes → rôles (noms de groupes configurables : `ARC_AUTH_ROLE_ADMIN_GROUP`, `ARC_AUTH_ROLE_PUBLISHER_GROUP`, `ARC_AUTH_ROLE_READER_GROUP`) :

| Groupe LDAP (`cn`) | Rôle |
|---|---|
| `arc-admins` | `ARC_ADMIN` |
| `arc-publishers` | `ARC_PUBLISHER` |
| `arc-readers` | `ARC_READER` |

Les branches de recherche dépendent de l'annuaire (`ou=Users`/`ou=Groups` par défaut, `ou=people`/`ou=groups` dans la démonstration) et se règlent avec `ARC_AUTH_LDAP_USER_SEARCH_BASE` et `ARC_AUTH_LDAP_GROUP_SEARCH_BASE`. Les groupes non listés ne produisent aucun rôle ; un utilisateur sans aucun rôle ARC ne reçoit pas de jeton (`401`). Aucun mot de passe, aucune donnée sensible autre que le nom d'affichage n'est placé dans le jeton.

## 6. Gestion des clés

| Sujet | Règle |
|---|---|
| Génération | Paire RSA 2048 bits minimum, créée hors du service et fournie par secret (`ARC_AUTH_JWT_PRIVATE_KEY_PATH`). En démonstration seulement, génération éphémère au démarrage (les jetons n'y survivent pas à un redémarrage). |
| Identification | `kid` dans chaque jeton ; le JWKS publie toutes les clés actives. |
| Rotation | Ajout de la nouvelle clé au JWKS (`ARC_AUTH_JWT_ADDITIONAL_PUBLIC_KEY_PATHS`, clés publiques PEM séparées par des virgules), bascule de la signature, retrait de l'ancienne après expiration du dernier jeton signé avec elle. |
| Algorithme | RS256 uniquement ; les services rejettent `none` et tout algorithme autre que celui attendu. |

## 7. Protection des services (ressource serveur)

`arc-publisher` et `product-manager` valident le jeton avec Spring Security `oauth2-resource-server` : récupération du JWKS via `jwk-set-uri` (à la demande, mise en cache, aucun appel au démarrage), contrôle de la signature, de `exp`/`nbf`, de `iss` et `aud`. Les rôles sont lus dans le claim `roles`. La configuration de sécurité est placée dans la couche **infrastructure** (`arc-publisher`) ou dans les adapters d'exposition (`product-manager`) ; le domaine n'a aucune dépendance à Spring Security. L'API est sans état : ni session ni protection CSRF, l'authentification Basic est refusée.

| Service | Endpoint | Rôle requis |
|---|---|---|
| `arc-publisher` | `POST /orders` | `ARC_PUBLISHER` ou `ARC_ADMIN` |
| `arc-publisher` | `DELETE /orders/{id}` | `ARC_PUBLISHER` ou `ARC_ADMIN` |
| `arc-publisher` | `GET /orders`, `GET /orders/{id}` | `ARC_READER`, `ARC_PUBLISHER` ou `ARC_ADMIN` |
| `product-manager` | `GET /products/**` | `ARC_READER`, `ARC_PUBLISHER` ou `ARC_ADMIN` |
| `product-manager` | `POST`, `PUT`, `DELETE` sur `/products/**` | `ARC_PUBLISHER` ou `ARC_ADMIN` |
| les deux | `/actuator/health` | public |
| les deux | tout autre chemin | refusé |

`product-manager`, qui appelle `arc-publisher`, s'authentifie auprès d'`arc-auth` avec un **compte de service** (variables `ARC_AUTH_USERNAME` et `ARC_AUTH_PASSWORD` ; compte placé par exemple sous `ou=ServiceAccounts` et membre de `arc-publishers`) et transmet le jeton obtenu. Le jeton est conservé jusqu'à 30 secondes avant son expiration puis renouvelé ; si `arc-publisher` le refuse (`401`), un nouveau jeton est demandé et l'appel est retenté une seule fois.

La transmission de `sub` (« qui a demandé ce provisioning ») dans les journaux et les métadonnées de l'ordre n'est pas encore implémentée (point ouvert 3).

## 8. Configuration

| Variable | Rôle | Défaut |
|---|---|---|
| `ARC_AUTH_LDAP_URL` | Annuaire | `ldap://localhost:10389` |
| `ARC_AUTH_LDAP_MANAGER_DN` / `ARC_AUTH_LDAP_MANAGER_PASSWORD` | Compte de service en lecture seule | — |
| `ARC_AUTH_LDAP_USER_SEARCH_BASE` | Base de recherche des utilisateurs | `ou=Users,dc=example,dc=com` |
| `ARC_AUTH_LDAP_USER_SEARCH_FILTER` | Filtre de recherche | `(uid={0})` |
| `ARC_AUTH_LDAP_GROUP_SEARCH_BASE` | Base de recherche des groupes | `ou=Groups,dc=example,dc=com` |
| `ARC_AUTH_JWT_ISSUER` | Valeur de `iss` | — |
| `ARC_AUTH_JWT_AUDIENCE` | Valeur de `aud` | `arc` |
| `ARC_AUTH_JWT_TTL` | Durée de vie du jeton | `PT15M` |
| `ARC_AUTH_JWT_PRIVATE_KEY_PATH` | Clé privée PEM | clé éphémère (démo seulement) |
| `ARC_AUTH_JWT_KEY_ID` | `kid` | empreinte SHA-256 de la clé publique |
| `ARC_AUTH_JWT_ADDITIONAL_PUBLIC_KEY_PATHS` | Clés publiques PEM supplémentaires publiées dans le JWKS (rotation) | — |
| `ARC_AUTH_ROLE_ADMIN_GROUP` / `_PUBLISHER_GROUP` / `_READER_GROUP` | Noms de groupes correspondant aux rôles | `arc-admins` / `arc-publishers` / `arc-readers` |
| `ARC_AUTH_RATE_LIMIT_MAX_FAILURES_PER_ADDRESS` / `_PER_IDENTIFIER` / `_WINDOW` | Limitation de débit des échecs | `20` / `5` / `PT5M` |

Côté services protégés (`arc-publisher`, `product-manager`) :

| Variable | Rôle | Défaut |
|---|---|---|
| `ARC_SECURITY_ISSUER_URI` | Valeur attendue de `iss` (obligatoire ; égale à `ARC_AUTH_JWT_ISSUER`). Aucune découverte OIDC : le JWKS est donné explicitement. | — |
| `ARC_SECURITY_JWK_SET_URI` | Clés publiques d'`arc-auth` | `http://localhost:8082/.well-known/jwks.json` (`arc-publisher`), `http://arc-auth:8082/.well-known/jwks.json` (`product-manager`) |
| `ARC_SECURITY_AUDIENCE` | Valeur attendue de `aud` | `arc` |

Côté `product-manager` uniquement : `ARC_AUTH_URL` (défaut `http://arc-auth:8082`), `ARC_AUTH_USERNAME` et `ARC_AUTH_PASSWORD` (compte de service, obligatoires).

## 9. Sécurité

- **TLS obligatoire** entre client et `arc-auth`, et entre `arc-auth` et l'annuaire (`ldaps://` / StartTLS) hors démonstration : le mot de passe transite en clair sinon.
- Réponse `401` uniforme ; aucun détail sur la cause de l'échec ; aucun mot de passe journalisé.
- Entrées échappées dans le filtre de recherche (protection contre l'injection LDAP).
- Durée de vie courte, pas de jeton de rafraîchissement : un jeton volé expire vite. Pas de liste de révocation en première version ; la révocation passe par la durée de vie et la rotation de clé.
- Compte de service de l'annuaire limité à la lecture des branches utilisateurs et groupes.
- En démonstration, les mots de passe sont publics et les ports liés à `127.0.0.1` ; ne jamais réutiliser ces valeurs.

## 10. Démonstration

`arc-auth` est ajouté à `demo/docker-compose.yml` (port `127.0.0.1:8082`), configuré sur le service Apache DS (document 12, section 5). Les comptes de démonstration ont des mots de passe **publics** : `alice` / `arc-demo-alice` (`ARC_ADMIN`, `ARC_READER`) et `bob` / `arc-demo-bob` (`ARC_READER`). Scénario :

```bash
# 1. Obtenir un jeton
TOKEN=$(curl -s -X POST http://localhost:8082/token \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"arc-demo-alice"}' | jq -r .access_token)

# 2. Appeler l'API protégée
curl -X POST http://localhost:8081/orders \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d @order.json
```

Sans jeton ou avec un jeton invalide, `arc-publisher` répond `401` ; avec `bob` (lecteur), `GET /orders` réussit et `POST /orders` répond `403`.

## 11. Plan de mise en œuvre

Réalisé :

1. `arc-auth` : API `/token` et `/.well-known/jwks.json`, bind LDAP, tests sur Apache DS embarqué.
2. Protection de `arc-publisher` (validation JWT, règles par rôle), tests d'API.
3. Ajout à la démonstration et mise à jour des README.
4. Protection de `product-manager` et utilisation du compte de service pour l'appel à `arc-publisher`.

## 12. Points ouverts

Tranchés : l'authentification est toujours imposée (pas de mode désactivé) ; les rôles de `product-manager` sont définis en section 7.

1. Stockage de la clé de signature en production (secret Kubernetes, coffre) : dépend de l'environnement de déploiement.
2. Besoin futur d'OIDC (fournisseur d'identité externe) : `arc-auth` pourrait alors être remplacé par un fournisseur du marché sans changer la validation côté services.
3. Traçabilité : transmettre `sub` du jeton dans les journaux et les métadonnées des ordres.
