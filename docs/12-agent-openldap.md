# 12 — Agent OpenLDAP, collecte LDAP temps réel et annuaire Apache DS

> **Statut : conception.** Ce document décrit des composants **non encore implémentés** (`arc-agent-openldap`, topic `iam.raw.ldap`, service Apache DS de démonstration). Il sert de référence avant le développement. Les points à valider par un essai sont listés en section 9.

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

- **OpenLDAP en production** : `accesslog` (valeurs avant/après, auteur de la modification) lu en `refreshAndPersist`.
- **Apache DS** (démo, tests) et tout serveur sans `accesslog` : Persistent Search ou Syncrepl selon ce que le serveur prend en charge, avec un **cache local d'entrées** pour reconstituer les anciennes valeurs (différence entre l'état précédent et l'état reçu). Le cache est reconstruit au démarrage par une recherche complète.
- La stratégie est choisie par configuration (`ARC_AGENT_LDAP_CHANGE_SOURCE=accesslog|syncrepl|persistent-search`).

### 4.4 Structure hexagonale

```
domain/
  model/      LdapChange (type, dn, entryUUID, changes, entry, auteur, horodatage)
  port/       LdapChangeSourcePort     (flux de changements, reprise par curseur)
              RawEventPublisherPort    (publication d'un événement brut)
              CursorStorePort          (persistance du cookie / dernier reqStart)
infrastructure/
  ldap/       PersistentSearchChangeSource, SyncreplChangeSource, AccessLogChangeSource
  kafka/      KafkaRawEventPublisher, KafkaCursorStore
application/
  service/    LdapCollectionService    (orchestration : source → enrichissement → publication)
```

Le domaine ne dépend d'aucune bibliothèque LDAP ni de Kafka. Le client LDAP utilisé dans les adaptateurs est à choisir parmi l'API Apache Directory LDAP (Apache-2.0) et UnboundID LDAP SDK (qui prend en charge Persistent Search et Content Sync) ; la compatibilité de licence avec EUPL-1.2 doit être vérifiée avant l'adoption (section 9).

### 4.5 Contrat du topic `iam.raw.ldap`

Clé Kafka : `entryUUID` (garantit l'ordre des changements d'une même entrée dans une partition). Message JSON :

```json
{
  "id": "LDAP01_9f1c2e7a-…_20260502T101500.123Z",
  "source": "ldap",
  "system": "ldap://LDAP01",
  "changeType": "modify",
  "dn": "uid=jdoe,ou=Users,dc=example,dc=com",
  "previousDn": null,
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

- `changeType` : `add`, `modify`, `delete`, `modrdn`.
- `changes[].old` n'est renseigné que si la source le permet (`accesslog`, cache) ; sinon il est absent.
- `entry` : état de l'entrée après le changement (absent pour `delete` ; l'ancien état est alors dans `changes` / cache).
- `origin` : `arc-agent` si `modifiedBy` est le compte de service de l'agent, `external` sinon (voir 4.7).

### 4.6 Correspondance vers le modèle ARC (consolidator)

Un mapper `LdapEventMapper` est ajouté à `arc-consolidator` (aujourd'hui seul le mapper Active Directory est opérationnel ; le mapper ISDS est un squelette). Le topic est configuré par `IAM_TOPICS_LDAP` (défaut `iam.raw.ldap`).

| Événement brut | Topic de sortie | `eventType` ARC | Champs |
|---|---|---|---|
| `add` d'une entrée `inetOrgPerson` | `arc.sync.identity` | `CREATED` | `name=uid`, `displayName=cn`, `externalId=entryUUID`, `type=user` |
| `modify` d'une identité | `arc.sync.identity` | `MODIFIED` | `changedAttributes` depuis `changes` |
| `delete` d'une identité | `arc.sync.identity` | `DELETED` | |
| `modrdn` | `arc.sync.identity` / `entitlement` | `RENAMED` | ancien DN dans `changedAttributes` |
| `add` / `modify` / `delete` d'un `groupOfNames` | `arc.sync.entitlement` | `CREATED` / `MODIFIED` / `DELETED` | `name=cn`, `externalId=entryUUID`, `type=group` |
| `modify` de `member` (valeur ajoutée) | `arc.sync.assignment` | `ADDED` | `identity` (membre), `entitlement` (groupe) |
| `modify` de `member` (valeur retirée) | `arc.sync.assignment` | `REMOVED` | idem |

Un seul `modify` portant plusieurs changements de `member` produit un événement d'assignation par valeur. Le membre technique d'un groupe (3.2) est ignoré.

Le `system` est repris tel quel (`ldap://LDAP01`) pour que `product-manager` et `arc-publisher` adressent l'agent de provisioning correspondant.

### 4.7 Boucle d'écho

Une écriture faite par l'agent de provisioning est elle-même observée par le module de collecte. Pour la distinguer :

- le compte de service de l'agent est connu (`ARC_AGENT_LDAP_BIND_DN`) ; l'attribut opérationnel `modifiersName` (Apache DS, OpenLDAP) ou `reqAuthzID` (`accesslog`) identifie l'auteur ;
- l'événement est publié avec `origin=arc-agent` et non supprimé : il reste utile à l'audit et à la confirmation d'exécution d'un job ;
- tout consommateur qui déclencherait un provisioning à partir de `arc.sync.*` doit ignorer les événements `origin=arc-agent` pour éviter une boucle. Le consolidator propage `origin` dans les événements `arc.sync.*`.

### 4.8 Fiabilité et reprise

| Sujet | Règle |
|---|---|
| **Livraison** | Au moins une fois ; la clé d'idempotence est `id` (système + `entryUUID` + horodatage/CSN). |
| **Reprise** | Le cookie Syncrepl (ou le dernier `reqStart` d'`accesslog`) est enregistré après publication Kafka acquittée, dans un topic Kafka compacté `iam.raw.ldap.cursor` (clé = `TARGET_SYSTEM`). |
| **Démarrage initial** | Pas de cookie : synchronisation complète (`refresh`), publiée avec `changeType=add` et `origin=initial-sync` ; le consolidator les traite comme un état et non comme des créations métier. |
| **Coupure de l'annuaire** | Reconnexion avec backoff exponentiel ; reprise depuis le curseur. Sans curseur valide (Persistent Search), nouvelle synchronisation complète puis comparaison avec le cache. |
| **Ordre** | Garanti par entrée (clé = `entryUUID`), pas entre entrées. |
| **Suppressions** | `accesslog` fournit l'ancienne entrée ; sinon le cache local fournit les attributs (Syncrepl ne renvoie que l'identifiant de l'entrée supprimée, sans attributs). |

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
- le module de collecte : une modification faite par le test produit le bon message `iam.raw.ldap` ;
- le `bind` d'authentification d'`arc-auth` (succès, mot de passe erroné, utilisateur inconnu).

L'intercepteur embarqué (4.2) est utilisable dans ce seul contexte pour tester l'adaptateur de collecte sans réseau ; il ne remplace pas les tests via Persistent Search / Syncrepl.

### 5.4 Démonstration (`demo/docker-compose.yml`)

Ajouts : `apacheds` et `arc-agent-openldap` sont en place (l'agent écrit réellement dans l'Apache DS local, `ARC_AGENT_DRY_RUN=false`). Restent à venir :

| Service | Rôle |
|---|---|
| `arc-agent-openldap` | Collecte temps réel (en plus du provisioning) |
| `arc-auth` | Émission de jetons JWT (voir document 13) |

Le service `topics-init` créera en plus `iam.raw.ldap` et `iam.raw.ldap.cursor` (compacté). Le service `arc-consolidator` recevra `IAM_TOPICS_LDAP`.

Scénario actuel : `POST /jobs` (`targetSystem` `ldap://LDAP01`) crée un utilisateur, un groupe et une affectation dans Apache DS, vérifiables avec `ldapsearch`. Scénario cible : modifier l'entrée `alice` avec `ldapmodify` ; l'événement apparaît dans `iam.raw.ldap` puis dans `arc.sync.identity` en quelques secondes ; le `POST /jobs` exige alors un jeton.

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

| Étape | Contenu | Dépôt |
|---|---|---|
| 1 | Squelette `arc-agent-openldap`, module d'exécution, tests sur Apache DS embarqué | `arc-agent-openldap` |
| 2 | Service Apache DS dans la démo (image `tgbyte/apacheds`, LDIF monté) | parent (`demo/`) |
| 3 | Module de collecte (Persistent Search puis Syncrepl, anti-écho, curseur), `LdapEventMapper` dans le consolidator | `arc-agent-openldap`, `arc-consolidator` |
| 4 | Source `accesslog` pour OpenLDAP | `arc-agent-openldap` |
| 5 | `arc-auth` et protection de `arc-publisher` / `product-manager` | voir document 13 |

Chaque dépôt suit les mêmes règles que les dépôts existants : licence EUPL-1.2, conformité REUSE, DCO, Conventional Commits, architecture hexagonale.

## 9. Points ouverts

1. **Support Syncrepl côté Apache DS** : à valider par essai (le fournisseur RFC 4533 d'Apache DS 2.x est à tester en `refreshAndPersist`). À défaut, Persistent Search avec cache.
2. **Client LDAP** : API Apache Directory LDAP (Apache-2.0) ou UnboundID LDAP SDK (multi-licence) ; vérifier la compatibilité avec EUPL-1.2 avant choix.
3. **Image `tgbyte/apacheds`** : image tierce à épingler par version et digest ; vérifier que l'image reste maintenue (sinon, repli sur une image construite par la démo).
4. **Version d'Apache DS** : `2.0.0.AM27` est une version « milestone » (pas de version finale 2.0.0) ; l'évolution du projet est à surveiller.
5. **Initial sync** : traitement par le consolidator des événements `origin=initial-sync` (état vs création métier).
