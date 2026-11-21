
# 11 — Collecte et consolidation des sources (Fluent Bit & Java)

## 1. Principe


La collecte des événements s’appuie sur **Fluent Bit** pour pousser les logs bruts dans des topics Kafka dédiés (ex : `iam.raw.activedirectory`).

Ensuite, un outil Java lit ces topics raw, consolide et normalise les événements, puis publie le résultat dans un topic final (ex : `arc`).

Schéma du flux :

```
[Source]              [Transport]         [Collecteur Fluent Bit]      [Topic Kafka RAW]         [Consolidation Java]         [Topic final]

AD (DCs)         ──► WEF             ──► input winlog             ──► iam.raw.activedirectory ──► Normalisation/Consolidation ──► arc
ISDS / equip.    ──► Syslog UDP/TLS  ──► input syslog             ──► iam.raw.isds            ──► ...                        ──► arc
... (autres)     ──► ...              ──► ...                     ──► iam.raw.{sourceId}       ──► ...                        ──► arc
```

---


## 2. Responsabilités

**Fluent Bit :**
- Collecte des données brutes (logs, events, etc.)
- Tagging technique (`sourceId`, `sourceType`, `collectorHost`, `zone`)
- Buffering local et publication fiable vers Kafka dans des topics `iam.raw.*`

**Outil Java de consolidation :**
- Consomme les topics `iam.raw.*` (ex : `iam.raw.activedirectory`)
- Normalise, enrichit et consolide les événements de toutes origines
- Publie les événements consolidés dans le topic final `arc`

**Projection (optionnelle) :**
- Les événements du topic `arc` peuvent ensuite être projetés dans une base (ex : PostgreSQL) ou d’autres systèmes cibles

---


## 3. Contrat de sortie de collecte (topic RAW)

Tous les collecteurs publient des messages JSON bruts vers `iam.raw.{sourceId}` avec métadonnées minimales et le payload natif.

Exemple pour Active Directory (event brut) :

```json
{
    "@timestamp": 1776625474.977771,
    "ProviderName": "Microsoft-Windows-Security-Auditing",
    "ProviderGuid": "{54849625-5478-4994-A5BA-3E3B0328C30D}",
    "Qualifiers": "",
    "EventID": 4720,
    "Version": 0,
    "Level": 0,
    "Task": 13824,
    "Opcode": 0,
    "Keywords": "0x8020000000000000",
    "TimeCreated": "2026-04-19 21:04:34 +0200",
    "EventRecordID": 4947125,
    "ActivityID": "",
    "RelatedActivityID": "",
    "ProcessID": 796,
    "ThreadID": 7924,
    "Channel": "Security",
    "Computer": "DC01.iap.local",
    "UserID": "",
    "Message": "A user account was created. ...",
    "StringInserts": [
        "wef-test-1454",
        "IAP",
        "S-1-5-21-984562994-3965904818-3631805304-1197",
        "S-1-5-21-984562994-3965904818-3631805304-500",
        "administrator",
        "IAP",
        "0x69f92",
        "-",
        "wef-test-1454",
        "-",
        "wef-test-1454@iap.local",
        "-",
        "-",
        "-",
        "-",
        "-",
        "%%1794",
        "%%1794",
        "513",
        "-",
        "0x0",
        "0x11",
        "\r\n\t\t%%2080\r\n\t\t%%2084",
        "-",
        "-",
        "%%1793"
    ]
}
```

Ce format brut est poussé dans le topic `iam.raw.activedirectory`.

---


## 4. Exemple de configuration Fluent Bit (WEC)

```ini
[SERVICE]
    Flush        1
    Log_Level    info

[INPUT]
    Name          winevtlog
    Channels      Security
    Tag           arc
    event_query   <QueryList><Query Id="0"><Select Path="Security">*[System[(EventID=4720 or EventID=4722 or EventID=4725 or EventID=4726 or EventID=4727 or EventID=4728 or EventID=4729 or EventID=4730 or EventID=4731 or EventID=4732 or EventID=4733 or EventID=4734 or EventID=4738 or EventID=4754 or EventID=4756 or EventID=4757 or EventID=4758)]]</Select></Query></QueryList>

[OUTPUT]
    Name         kafka
    Match        arc
    Brokers      kafka.iap.local:30092
    Topics       iam.raw.activedirectory
    Format       json
    rdkafka.request.required.acks all

[OUTPUT]
    Name         stdout
    Match        arc
```

---


## 5. Consolidation et format cible (topic arc)

L’outil Java lit les topics `iam.raw.*`, extrait et normalise les informations clés, puis publie dans le topic final `arc` au format cible (exemple à adapter selon le modèle ARC attendu) :

```json
{
    "event_time": "2026-04-19T21:04:34+02:00",
    "event_type": "user_created",
    "source": "activedirectory",
    "user": {
        "account_name": "wef-test-1454",
        "domain": "IAP",
        ...
    },
    ...
}
```

Ce format cible est commun à toutes les sources et permet la corrélation et l’exploitation unifiée des événements.

- Plusieurs collecteurs Fluent Bit par zone (Tier0, Prod, Cloud).
- Un collecteur par region si necessaire.
- Pas de dependance a un binaire de collecte specifique metier.

---


## 6. Décision d’architecture

- Fluent Bit est la brique unique de collecte pour toutes les sources (plus d’agent Java de collecte).
- L’outil Java se concentre sur la consolidation, la normalisation et la publication dans le topic cible (`arc`).
- Les projections vers des bases ou autres systèmes se font à partir du topic `arc`.