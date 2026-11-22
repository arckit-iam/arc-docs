# 12 — Agent OpenLDAP, collecte LDAP temps réel et annuaire Apache DS

> **Statut : implémenté et validé sur Apache DS** (étapes 1 à 3 du plan, section 8) : module d'exécution, collecte temps réel par Persistent Search, `LdapEventMapper` du consolidator, service Apache DS de la démonstration. **Reste à faire** : source `accesslog` / Syncrepl pour OpenLDAP (étape 4, à valider sur un vrai OpenLDAP) et `arc-auth` (étape 5). Les points ouverts sont en section 9.

## 1. Objectifs et périmètre

| Objectif | Description |
|---|---|
| **Provisioning** | Un agent `arc-agent-openldap` exécute sur un annuaire LDAP (OpenLDAP, Apache DS, tout serveur LDAPv3 de schéma `inetOrgPerson` / `groupOfNames`) les ordres publiés sur `arc.provisioning.*`. Même contrat que `arc-agent-ad`. |
| **Collecte temps réel** | Chaque modification de l'annuaire (ajout, modification, suppression, renommage) est poussée vers Kafka (`iam.raw.ldap`) dès qu'elle survient, sans polling périodique. |
| **Annuaire local** | Un annuaire **Apache Directory Server** sert de cible dans la démonstration (conteneur) et dans les tests d'intégration (instance embarquée). |
| **Authentification** | L'annuaire sert aussi de référentiel d'authentification pour `arc-auth` (voir [13-authentification-jwt.md](13-authentification-jwt.md)). |

Hors périmètre : réplication d'annuaire à annuaire, gestion des mots de passe (politique, expiration), synchronisation bidirectionnelle automatique.

## 2. Place dans l'architecture

```
                     COLLECTE (temps réel)
 ┌──────────────┐  Persistent Search / Syncrepl /     ┌─────────────────┐
 │  Annuaire    │  accesslog                          │ arc-agent-      │
 │  LDAP        │ ───────────────────────────────────►│ openldap        │
 │ (OpenLDAP /  │                                     │ (module collecte)│
 │  Apache DS)  │◄───────────────────────────────────┐└────────┬────────┘
 └──────────────┘   PROVISIONING (LDAP add/modify/    │         │ iam.raw.ldap
                    delete)                           │         ▼
                                              ┌───────┴────────┐   ┌──────────────────┐
                                              │ arc-agent-     │   │ arc-consolidator │
                                              │ openldap       │   │ (mapper LDAP)    │
                                              │ (module exec.) │   └────────┬─────────┘
                                              └───────▲────────┘            │ arc.sync.*
                                                      │ arc.provisioning.*  ▼
                                              ┌───────┴────────┐   ┌──────────────────┐
                                              │ arc-publisher  │◄──│ product-manager  │
                                              └────────────────┘   └──────────────────┘
```

L'agent regroupe deux responsabilités indépendantes, activables séparément par configuration :

- **module d'exécution** : consomme `arc.provisioning.{identity,entitlement,assignment}` et écrit dans l'annuaire ;
- **module de collecte** : observe l'annuaire et publie les changements sur `iam.raw.ldap`.

Un déploiement = une instance par annuaire cible (`TARGET_SYSTEM=ldap://LDAP01`), comme pour `arc-agent-ad`.

## 3. Module d'exécution (provisioning)

### 3.1 Contrat d'entrée

Identique à `arc-agent-ad` : le record `ProvisioningCommand` (champs `jobId`, `action`, `identityId`, `identityName`, `targetSystem`, `entitlementId`, `entitlementName`, `scope`, `changedAttributes`, `executeAt`, `correlationId`, `type`). L'agent ignore toute commande dont `targetSystem` ne correspond pas à son `TARGET_SYSTEM` (préfixe `ldap://`). Le type de topic détermine l'objet visé.

### 3.2 Actions

| Topic | Action | Opération LDAP |
|---|---|---|
| `arc.provisioning.identity` | `CREATE` | `add` d'une entrée `inetOrgPerson` sous `usersOu` |
| | `MODIFY` | `modify` (`replace`) des attributs de `changedAttributes` |
| | `DELETE` | `delete` de l'entrée |
| `arc.provisioning.entitlement` | `CREATE` / `MODIFY` / `DELETE` | idem, pour une entrée `groupOfNames` sous `groupsOu` |
| `arc.provisioning.assignment` | `CREATE` / `ADD` | `modify` `add member` sur le groupe |
| | `DELETE` / `REMOVE` | `modify` `delete member` sur le groupe |

Les opérations sont idempotentes (Kafka livre au moins une fois) : créer une entrée existante, supprimer une entrée absente, ajouter un membre déjà présent ou retirer un non-membre est journalisé et ignoré. Pour un groupe, `entitlementId` est le `cn` du groupe.

Particularités du schéma `groupOfNames` : l'attribut `member` est **obligatoire** (un groupe ne peut pas être vide). La création d'un groupe insère donc un membre technique (`member=cn=placeholder,...` configurable, par défaut le compte de service de l'agent) ; le retrait du dernier vrai membre ne supprime pas ce membre technique.

### 3.3 Correspondance des attributs

| Attribut ARC (`changedAttributes.name`) | Attribut LDAP |
|---|---|
| `email` | `mail` |
| `firstName` | `givenName` |
| `lastName` | `sn` |
| `displayName` | `cn` / `displayName` |
| `phone` | `telephoneNumber` |
| identifiant (`identityId`) | `uid` (et RDN `uid=<identityId>`) |

Les attributs inconnus sont ignorés avec un avertissement (jamais écrits à l'aveugle). Le DN d'une entrée est construit à partir du RDN et de `usersOu` / `groupsOu` ; aucun DN n'est repris tel quel d'un message sans validation de son suffixe (voir section 7).

### 3.4 Dry-run

Avec `ARC_AGENT_DRY_RUN=true` (défaut recommandé tant que l'annuaire cible n'est pas validé), l'agent journalise l'opération sans l'exécuter, au même format que `arc-agent-ad` :

```
[DRY-RUN] jobId=.. action=.. topic=.. identity=.. targetSystem=.. executeAt=..
```

### 3.5 Configuration

| Variable | Rôle | Défaut |
|---|---|---|
| `SPRING_KAFKA_BOOTSTRAP_SERVERS` | Broker Kafka | `localhost:9092` |
| `ARC_TOPICS_PROVISIONING_IDENTITY` / `_ASSIGNMENT` / `_ENTITLEMENT` | Topics consommés | `arc.provisioning.identity` / `.assignment` / `.entitlement` |
| `TARGET_SYSTEM` | Annuaire cible géré par cette instance | `ldap://LDAP01` |
| `ARC_AGENT_CONSUMER_GROUP` | Groupe de consommateurs | `arc-agent-openldap` |
| `ARC_AGENT_DRY_RUN` | Simulation sans écriture | `true` |
| `ARC_AGENT_LDAP_URL` | URL de l'annuaire (`ldaps://` en production) | `ldap://localhost:10389` |
| `ARC_AGENT_LDAP_BASE_DN` | Racine de l'annuaire | `dc=example,dc=com` |
| `ARC_AGENT_LDAP_BIND_DN` / `ARC_AGENT_LDAP_BIND_PASSWORD` | Compte de service de l'agent | — |
| `ARC_AGENT_LDAP_USERS_OU` / `ARC_AGENT_LDAP_GROUPS_OU` | Branches des identités et groupes, relatives à `BASE_DN` | `ou=Users` / `ou=Groups` |
| `ARC_AGENT_LDAP_GROUP_PLACEHOLDER_MEMBER` | Membre technique d'un groupe (voir 3.2) | compte de service, sinon `cn=arc-placeholder,<baseDn>` |

Les mots de passe sont fournis par secret (jamais par image ni par dépôt).

## 4. Module de collecte temps réel

### 4.1 Question de l'adaptation d'Apache DS

**Il n'est pas nécessaire de forker Apache DS** : un serveur LDAP expose déjà des mécanismes standard pour suivre ses changements en continu. Le collecteur est un **client** de l'annuaire et reste ainsi indépendant du serveur utilisé.

### 4.2 Mécanismes disponibles

| Mécanisme | Principe | Valeurs avant/après | Suppressions | Remarques |
|---|---|---|---|---|
| **Persistent Search** (contrôle `2.16.840.1.113730.3.4.3`, brouillon IETF) | Recherche qui reste ouverte ; le serveur pousse une notification par changement | Entrée après modification ; type de changement et ancien DN (renommage) ; **pas d'ancienne valeur** | Notifiées (DN) | Simple ; non normalisé RFC ; pas de reprise après coupure |
| **Syncrepl / Content Sync** (RFC 4533, mode `refreshAndPersist`) | Synchronisation initiale puis flux continu ; cookie de reprise | Entrée après modification | Notifiées (identifiant `entryUUID`, sans attributs) | Normalisé ; reprise via cookie ; support serveur à valider (OpenLDAP : oui) |
| **Overlay `accesslog`** (OpenLDAP, `slapo-accesslog`) | Journal des écritures dans une base dédiée (`cn=accesslog`), observable par recherche ou Syncrepl | **Oui** (`reqMod`, et `reqOld` avec `logold` / `logoldattr`) | Oui, avec l'ancienne entrée | Source la plus riche ; spécifique à OpenLDAP |
| **Intercepteur embarqué** (Apache DS) | Code Java branché dans la chaîne d'interception du serveur | Oui | Oui | Uniquement si Apache DS est embarqué dans le même processus (tests) ; pas pour un serveur distant |

### 4.3 Choix retenu

- **Apache DS** (démo, tests), seule source implémentée et validée : **Persistent Search**, avec un **cache local d'entrées** pour reconstituer les anciennes valeurs (différence entre l'état précédent et l'état reçu). Essai réalisé : Apache DS **refuse Syncrepl** (`Replication is not allowed on this server`) ; Persistent Search fournit en revanche `entryUUID`, `createTimestamp` / `modifyTimestamp` et l'auteur (`creatorsName`, `modifiersName`).
- **OpenLDAP en production** (étape 4, non implémentée) : `accesslog` (valeurs avant/après, auteur de la modification) lu en `refreshAndPersist`, ou Syncrepl. À valider sur un vrai OpenLDAP.
- Le choix de la source par configuration (`ARC_AGENT_LDAP_CHANGE_SOURCE`) est prévu avec l'étape 4 ; une seule source existe aujourd'hui.
- La collecte se déroule **dans l'agent**, activée par `ARC_AGENT_COLLECTION_ENABLED=true` (désactivée par défaut). Elle est événementielle : aucun polling, aucune relecture complète de l'annuaire pour publier (voir 4.8).

### 4.4 Structure hexagonale

```
domain/
  model/      LdapChange, LdapEntry, LdapNotification, AttributeChange, LdapChangeType
  port/       LdapChangeSourcePort     (open : flux de notifications ; modifiedSince : rattrapage ; snapshot)
              RawEventPublisherPort    (publication d'un changement)
              CursorStorePort          (persistance du curseur de reprise)
              OwnWriteRegistryPort     (mémoire des écritures de l'agent, anti-écho)
infrastructure/
  ldap/       PersistentSearchChangeSource, InMemoryOwnWriteRegistry, LdapProvisioningHandler
  kafka/      KafkaRawEventPublisher, KafkaCursorStore
application/
  LdapCollectionService    (orchestration : flux → différence avec le cache → publication → curseur)
```

Le domaine ne dépend d'aucune bibliothèque LDAP ni de Kafka. Le client LDAP est l'**API Apache Directory LDAP 2.1.5** (Apache-2.0, compatible avec EUPL-1.2). UnboundID LDAP SDK a été écarté pour des raisons de licence.

### 4.5 Contrat du topic `iam.raw.ldap`

Clé Kafka : `entryUUID` (garantit l'ordre des changements d'une même entrée dans une partition). Message JSON :

```json
{
  "id": "LDAP01_9f1c2e7a-…_20260502T101500.123Z",
  "source": "ldap",
  "system": "ldap://LDAP01",
  "changeType": "modify",
  "dn": "uid=jdoe,ou=Users,dc=example,dc=com",
  "entryUUID": "9f1c2e7a-…",
  "objectClasses": ["top", "person", "organizationalPerson", "inetOrgPerson"],
  "timestamp": "2026-05-02T10:15:00.123Z",
  "modifiedBy": "uid=admin,ou=system",
  "origin": "external",
  "changes": [
    { "attribute": "mail", "op": "replace", "old": ["j.doe@example.com"], "new": ["john.doe@example.com"] }
  ],
  "entry": { "uid": ["jdoe"], "cn": ["John Doe"], "mail": ["john.doe@example.com"] }
}
```

- Les champs sans valeur sont omis (`previousDn` hors `modrdn`, `modifiedBy` et `entry` pour `delete`).
- `changeType` : `add`, `modify`, `delete`, `modrdn`.
- `changes[].op` : `add`, `replace` ou `delete` ; `old` et `new` sont des listes de valeurs. Les anciennes valeurs viennent du cache local de l'agent.
- `entry` : état de l'entrée après le changement, sans attribut opérationnel ni mot de passe (`userPassword`, `unicodePwd`). Absent pour `delete` : les derniers attributs connus sont alors dans `changes` (`op=delete`).
- `timestamp` : `modifyTimestamp` de l'annuaire (précision d'une seconde) ; pour un `delete`, heure de publication par l'agent.
- `modifiedBy` : auteur lisible rapporté par l'annuaire, **à titre informatif** (voir 4.7 : il n'est pas fiable pour distinguer l'origine).
- `origin` : `arc-agent` (écriture de l'agent), `external` (autre écriture), `catch-up` (rattrapage au redémarrage ou après une coupure), `reconcile` (suppression constatée après une coupure).

### 4.6 Correspondance vers le modèle ARC (consolidator)

Le mapper `LdapEventMapper` d'`arc-consolidator` (service `LdapConsolidatorService`, consommateur `RawLdapEventConsumer`) est implémenté. Le topic est configuré par `IAM_TOPICS_LDAP` (défaut `iam.raw.ldap`).

| Événement brut | Topic de sortie | `eventType` ARC | Champs |
|---|---|---|---|
| `add` d'une entrée `inetOrgPerson` | `arc.sync.identity` | `CREATED` | `name=uid`, `displayName=cn`, `externalId=entryUUID`, `type=user` |
| `modify` d'une identité | `arc.sync.identity` | `MODIFIED` | `changedAttributes` depuis `changes` |
| `delete` d'une identité | `arc.sync.identity` | `DELETED` | |
| `modrdn` | `arc.sync.identity` / `entitlement` | `RENAMED` | ancien DN dans `changedAttributes` |
| `add` / `modify` / `delete` d'un `groupOfNames` | `arc.sync.entitlement` | `CREATED` / `MODIFIED` / `DELETED` | `name=cn`, `externalId=entryUUID`, `type=group` |
| `modify` de `member` (valeur ajoutée) | `arc.sync.assignment` | `ADDED` | `identity` (membre), `entitlement` (groupe) |
| `modify` de `member` (valeur retirée) | `arc.sync.assignment` | `REMOVED` | idem |

Un seul `modify` portant plusieurs changements de `member` produit un événement d'assignation par valeur ; un groupe créé avec des membres produit une assignation `ADDED` par membre. Un `modify` qui ne touche que `member` ne produit pas d'événement de droit. Les autres classes d'objets sont ignorées.

Le membre technique d'un groupe (3.2) est ignoré : `IAM_LDAP_IGNORED_MEMBERS` liste ses DN, **séparés par des points-virgules** (une virgule fait partie d'un DN). Dans la démonstration : `uid=admin,ou=system`.

Le `system` est repris tel quel (`ldap://LDAP01`) pour que `product-manager` et `arc-publisher` adressent l'agent de provisioning correspondant. `origin` est propagé dans les événements `arc.sync.*` (nouveau champ optionnel des DTO).

Le consolidator écarte un message déjà traité, repéré par son `id` (10 000 identifiants récents en mémoire) : l'agent peut republier un changement au redémarrage (4.8). Cette mémoire est celle du processus ; après un redémarrage du consolidator, un doublon peut repasser.

Limites : un groupe supprimé produit l'événement de droit `DELETED` mais pas d'assignations `REMOVED` ; l'`externalId` de l'identité d'une assignation est vide (le message brut ne donne que le DN du membre).

### 4.7 Boucle d'écho

Une écriture faite par l'agent de provisioning est elle-même observée par le module de collecte. Pour la distinguer :

- **Comparer l'auteur au compte de service ne suffit pas**, constaté sur Apache DS : une notification d'ajout n'a pas de `modifiersName` (seulement `creatorsName`), l'auteur arrive sous forme normalisée (OID et espaces, rendu lisible par le schéma), et pour une suppression l'auteur rapporté est le précédent auteur de l'entrée, pas celui qui supprime ;
- l'agent tient donc une **mémoire en RAM de ses propres écritures** (`OwnWriteRegistryPort`) : le module d'exécution enregistre le couple (DN, type de changement) avant chaque écriture ; le module de collecte le consomme une seule fois à la notification correspondante et marque alors l'événement `origin=arc-agent`. Durée de vie d'une entrée : `ARC_AGENT_COLLECTION_OWN_WRITE_TTL` (30 s). Limites : la mémoire est locale à un processus d'agent, et une écriture externe sur le même DN et le même type dans cette fenêtre serait marquée à tort `arc-agent` ;
- l'événement est publié avec `origin=arc-agent` et non supprimé : il reste utile à l'audit et à la confirmation d'exécution d'un job ;
- tout consommateur qui déclencherait un provisioning à partir de `arc.sync.*` doit ignorer les événements `origin=arc-agent` pour éviter une boucle. Le consolidator propage `origin` dans les événements `arc.sync.*`.

### 4.8 Fiabilité et reprise

| Sujet | Règle |
|---|---|
| **Livraison** | Au moins une fois ; l'identifiant d'un message est `<système>_<entryUUID>_<horodatage>` et sert de clé d'idempotence au consolidator. La clé Kafka est `entryUUID`. L'envoi est synchrone (acquittement attendu, 10 s). |
| **Curseur** | Dernier `modifyTimestamp` publié, enregistré après publication Kafka acquittée dans le topic compacté `iam.raw.ldap.cursor` (clé = `TARGET_SYSTEM`, valeur = instant ISO). Si la publication échoue, le curseur n'avance pas et le changement est rejoué par le rattrapage. |
| **Premier démarrage** | Pas de curseur : **rien n'est publié**. L'état courant de l'annuaire est lu pour remplir le cache (sans publication) et le curseur est placé sur la dernière modification existante. Pas de `origin=initial-sync` : la reprise d'un état existant n'est pas faite par la collecte. |
| **Redémarrage** | Pas de relecture complète pour publier : le **rattrapage** interroge les entrées modifiées depuis le curseur (`modifyTimestamp >=`) et les publie avec `origin=catch-up`. La dernière entrée déjà envoyée peut être republiée (cache vide, `modifyTimestamp` à la seconde) ; le consolidator écarte le doublon par `id`. |
| **Coupure de l'annuaire** | La session est relancée après `ARC_AGENT_COLLECTION_RETRY_DELAY` (délai fixe, 10 s) : flux rouvert, rattrapage depuis le curseur, puis lecture de l'état courant ; les entrées du cache qui ont disparu sont publiées comme supprimées (`origin=reconcile`). |
| **Doublons** | Une notification sans différence d'attribut avec le cache est ignorée (la date ne suffit pas : `modifyTimestamp` n'a qu'une précision d'une seconde). |
| **Ordre** | Garanti par entrée (clé = `entryUUID`), pas entre entrées. |
| **Suppressions** | Les derniers attributs connus viennent du cache local (Persistent Search et Syncrepl ne renvoient pas l'ancienne entrée) ; `accesslog` les fournirait nativement (étape 4). |

### 4.9 Configuration de la collecte

| Variable | Rôle | Défaut |
|---|---|---|
| `ARC_AGENT_COLLECTION_ENABLED` | Active le module de collecte | `false` |
| `ARC_TOPICS_RAW_LDAP` | Topic des changements bruts | `iam.raw.ldap` |
| `ARC_TOPICS_RAW_LDAP_CURSOR` | Topic compacté du curseur (créé avec `cleanup.policy=compact`) | `iam.raw.ldap.cursor` |
| `ARC_AGENT_COLLECTION_FILTER` | Filtre LDAP des entrées suivies | `(\|(objectClass=inetOrgPerson)(objectClass=groupOfNames))` |
| `ARC_AGENT_COLLECTION_RETRY_DELAY` | Délai avant une nouvelle session après une coupure | `10s` |
| `ARC_AGENT_COLLECTION_OWN_WRITE_TTL` | Durée de mémorisation d'une écriture de l'agent (4.7) | `30s` |
| `ARC_AGENT_COLLECTION_TIMEOUT` | Délai des requêtes LDAP ordinaires | `30s` |

Côté consolidator : `IAM_TOPICS_LDAP` (`iam.raw.ldap`) et `IAM_LDAP_IGNORED_MEMBERS` (4.6).

Le délai des requêtes ordinaires **n'est pas appliqué** à la connexion d'écoute : sinon Apache DS voit la recherche persistante coupée après environ 30 s de silence (constaté en démonstration).

### 4.10 Limites connues

- Une modification survenue pendant les quelques millisecondes du démarrage peut être manquée.
- Le cache contient tout l'annuaire suivi, en mémoire.
- Une suppression survenue pendant l'arrêt de l'agent n'est pas détectée (cache vide au redémarrage) ; elle l'est après une simple coupure de connexion.
- Une coupure réseau silencieuse n'est pas détectée (pas de keepalive applicatif).
- La mémoire anti-écho est locale à un processus (4.7).
- Les adaptateurs Kafka n'ont pas de test unitaire ; ils sont validés par la démonstration.

## 5. Annuaire Apache Directory Server

### 5.1 Rôle

Apache DS est l'annuaire **de développement et de démonstration** : léger, 100 % Java, installable sans infrastructure. Il n'est pas la cible de production visée (OpenLDAP, Active Directory, annuaires du marché).

### 5.2 Conteneur de démonstration

Le projet Apache DS ne publie pas d'image Docker officielle. La démo utilise l'image communautaire **`tgbyte/apacheds`** (Apache-2.0, Apache DS `2.0.0.AM27`, JRE 21, `linux/amd64`, maintenue en 2026), **sans construire d'image propre**. Elle est épinglée par version (et idéalement par digest) ; les alternatives `reucon/apacheds` (également maintenue) et `openmicroscopy/apacheds` (peu active) ont été écartées. `itzg/apacheds`, la plus téléchargée, est abandonnée depuis 2016.

| Élément | Valeur |
|---|---|
| Image | `tgbyte/apacheds:2.0.0.AM27` |
| Port LDAP | `10389` (exposé sur `127.0.0.1` uniquement) |
| Port LDAPS | `10636` (optionnel) |
| Racine | `APACHEDS_DOMAIN_NAME=arc`, `APACHEDS_DOMAIN_SUFFIX=local` : `dc=arc,dc=local` (l'image crée `ou=people` et `ou=groups`) |
| Compte d'administration | `uid=admin,ou=system` ; `APACHEDS_ADMIN_PASSWORD` doit être défini (le défaut `secret` est connu de tous) |
| Données initiales | fichiers LDIF montés dans `/ldif.d/`, importés au premier démarrage |
| Persistance | volume `/var/lib/apacheds` (optionnel en démo) |

Points de vigilance : image tierce non auditée par le projet Apache (utilisée uniquement pour la démonstration, jamais en production) ; les fichiers de `/ldif.d/` ne sont importés qu'une fois, tant que le volume n'est pas réinitialisé.

Arborescence de démonstration :

```
dc=arc,dc=local
├── ou=people
│   ├── uid=alice      (inetOrgPerson)
│   └── uid=bob
└── ou=groups
    ├── cn=arc-admins      (member: alice)
    └── cn=arc-readers     (member: alice, bob)
```

Les groupes `arc-*` alimenteront les rôles de `arc-auth` (voir document 13) ; les groupes créés par provisioning (par exemple `demo-readers`) servent d'entitlements de démonstration.

### 5.3 Instance embarquée dans les tests

Les tests d'intégration de `arc-agent-openldap` et de `arc-auth` démarrent une instance Apache DS **dans le processus de test** (partition en mémoire, LDIF de test, port éphémère). Ils couvrent :

- chaque action de provisioning (3.2) contre un vrai annuaire ;
- le module de collecte : une modification faite par le test produit le bon message de changement, avec le bon `origin`, l'auteur lisible et sans coupure du flux après plusieurs secondes de silence ;
- le `bind` d'authentification d'`arc-auth` (succès, mot de passe erroné, utilisateur inconnu).

L'intercepteur embarqué (4.2) n'est pas utilisé : les tests passent par Persistent Search, comme en démonstration.

### 5.4 Démonstration (`demo/docker-compose.yml`)

Ajouts réalisés : `apacheds` et `arc-agent-openldap` sont en place (l'agent écrit réellement dans l'Apache DS local, `ARC_AGENT_DRY_RUN=false`, collecte activée par `ARC_AGENT_COLLECTION_ENABLED=true`). Les services `topics-init` et `topics-init-compacted` créent `iam.raw.ldap` et `iam.raw.ldap.cursor` (compacté) ; `arc-consolidator` reçoit `IAM_TOPICS_LDAP` et `IAM_LDAP_IGNORED_MEMBERS`. Reste à venir :

| Service | Rôle |
|---|---|
| `arc-auth` | Émission de jetons JWT (voir document 13) |

La collecte et la consolidation LDAP ne fonctionnent avec les images publiées (`:stable`) qu'à partir des versions qui les contiennent (agent 0.2.0 et la version suivante du consolidator) ; avant cela, utiliser des images construites localement.

Scénario : `POST /jobs` (`targetSystem` `ldap://LDAP01`) crée un utilisateur, un groupe et une affectation dans Apache DS, vérifiables avec `ldapsearch` ; chaque écriture réapparaît dans `iam.raw.ldap` avec `origin=arc-agent`. Modifier l'entrée `alice` avec `ldapmodify` produit un message `origin=external` dans `iam.raw.ldap`, puis un événement `MODIFIED` dans `arc.sync.identity` en quelques secondes (de même, l'ajout ou le retrait d'un `member` produit une assignation `ADDED` ou `REMOVED` dans `arc.sync.assignment`). Scénario cible : le `POST /jobs` exige alors un jeton.

## 6. Observabilité

- Journaux structurés par commande (`jobId`, `correlationId`) et par changement collecté (`entryUUID`).
- Métriques (Actuator / Micrometer) : commandes exécutées / rejetées, changements collectés, retard de collecte (horodatage du changement – horodatage de publication), état de la connexion LDAP.
- Sonde de santé : connexion LDAP et connexion Kafka.

## 7. Sécurité

| Sujet | Mesure |
|---|---|
| Transport | `ldaps://` ou StartTLS obligatoire hors démonstration ; vérification du certificat (truststore monté en volume, cf. README d'`arc-agent-ad`). |
| Compte de service | Droits minimaux : écriture sur `usersOu` et `groupsOu` uniquement ; lecture (et accès à `cn=accesslog` le cas échéant) pour la collecte. Deux comptes distincts recommandés (écriture / lecture). |
| Validation des entrées | Échappement des valeurs dans les DN et filtres (RFC 4514 / 4515) ; rejet d'un DN hors du suffixe configuré ; liste blanche d'attributs modifiables. |
| Secrets | Fournis par secret d'exécution, jamais journalisés. |
| Démonstration | Mots de passe de démo documentés comme tels ; ports liés à `127.0.0.1`. |
| Données personnelles | `iam.raw.ldap` contient des attributs d'identité ; durée de rétention du topic alignée sur `05-publication-messaging.md`. |

## 8. Plan de mise en œuvre

| Étape | Contenu | Dépôt | État |
|---|---|---|---|
| 1 | Squelette `arc-agent-openldap`, module d'exécution, tests sur Apache DS embarqué | `arc-agent-openldap` | fait |
| 2 | Service Apache DS dans la démo (image `tgbyte/apacheds`, LDIF monté) | parent (`demo/`) | fait |
| 3 | Module de collecte (Persistent Search, anti-écho, curseur), `LdapEventMapper` dans le consolidator | `arc-agent-openldap`, `arc-consolidator` | fait, validé en démonstration |
| 4 | Source `accesslog` / Syncrepl pour OpenLDAP | `arc-agent-openldap` | à faire |
| 5 | `arc-auth` et protection de `arc-publisher` / `product-manager` | voir document 13 | à faire |

Chaque dépôt suit les mêmes règles que les dépôts existants : licence EUPL-1.2, conformité REUSE, DCO, Conventional Commits, architecture hexagonale.

## 9. Points ouverts

1. **Syncrepl et `accesslog` sur OpenLDAP** : à valider sur un vrai OpenLDAP (étape 4). Apache DS refuse Syncrepl (constaté) ; Persistent Search y est la seule source.
2. **Client LDAP** : tranché, API Apache Directory LDAP 2.1.5 (Apache-2.0). UnboundID écarté pour sa licence.
3. **Image `tgbyte/apacheds`** : image tierce à épingler par version et digest (aujourd'hui par version seulement) ; vérifier qu'elle reste maintenue (sinon, repli sur une image construite par la démo).
4. **Version d'Apache DS** : `2.0.0.AM27` est une version « milestone » (pas de version finale 2.0.0) ; l'évolution du projet est à surveiller.
5. **Reprise d'un état existant** : la collecte ne publie rien au premier démarrage (4.8). Un import initial d'un annuaire déjà peuplé reste à définir (outil dédié ou publication explicite), ainsi que le traitement des suppressions survenues pendant un arrêt de l'agent.
