# 06 — Cas d'Usage SOC (Security Operations Center)

## 1. Positionnement dans le SOC

La plateforme d'événements AD s'intègre dans la chaîne SOC comme **source de données en temps réel**, complétant ou remplaçant la collecte Syslog/Windows Events traditionnelle.

```
                    ┌─────────────────────────────────────┐
                    │            SOC                      │
                    │                                     │
  ad.iam.alert ──►  │  ┌──────────────────────────────┐  │
  ad.iam.identity ► │  │  SIEM                        │  │
  ad.iam.group ──►  │  │  (Splunk / Elastic / QRadar) │  │
                    │  │  - Corrélation multi-sources  │  │
                    │  │  - Dashboards temps réel      │  │
                    │  └──────────────┬───────────────┘  │
                    │                 │                   │
                    │  ┌──────────────▼───────────────┐  │
                    │  │  SOAR                        │  │
                    │  │  (Palo Alto XSOAR / Splunk   │  │
                    │  │   SOAR / TheHive)            │  │
                    │  │  - Playbooks automatisés     │  │
                    │  │  - Réponse automatique       │  │
                    │  └──────────────┬───────────────┘  │
                    │                 │                   │
                    │       Analyste SOC                  │
                    └─────────────────────────────────────┘
```

---

## 2. Règles de détection MITRE ATT&CK

### 2.1 Privilege Escalation — T1078.002 (Domain Accounts)

**Scénario** : Un attaquant crée un compte et l'ajoute immédiatement à un groupe privilégié.

```
RÈGLE: PRIV-ESC-001
Condition:
  membership.added
  AND group.sensitivityLevel IN (HIGH, CRITICAL)
  AND (
    actor.isServiceAccount = true
    OR isOutsideBusinessHours = true
    OR (
      corr avec account.created pour le même member.sid
      dans une fenêtre de 10 minutes
    )
  )
Sévérité: CRITICAL
MITRE: T1078.002 — Privilege Escalation / Valid Accounts: Domain Accounts
Action: Alerte immédiate + ticket SOAR
```

**Exemple de playbook SOAR** :
1. Vérifier si la demande correspond à un ticket de changement approuvé (ServiceNow API)
2. Si non, **désactiver le compte** concerné (AD API) + notification manager
3. Ouvrir un incident P1 dans le ITSM
4. Capturer la session RDP active si entamée (endpoint isolation)

---

### 2.2 Persistence — T1098 (Account Manipulation)

**Scénario** : Modification des attributs d'un compte (ex. `AdminCount = 1`, ajout à `AdminSDHolder`).

```
RÈGLE: PERSIST-001
Condition:
  account.modified
  AND (
    changedAttributes CONTAINS "adminCount"
    OR changedAttributes CONTAINS "servicePrincipalName"
    OR changedAttributes CONTAINS "msDS-AllowedToDelegateTo"
  )
Sévérité: HIGH
MITRE: T1098 — Persistence / Account Manipulation
```

---

### 2.3 Discovery — T1069 (Permission Groups Discovery)

**Scénario** : Un compte non privilégié effectue de nombreuses lectures de groupes.

```
RÈGLE: DISC-001 (corrélation avec logs d'authentification)
Condition:
  Compte X interroge > 20 groupes différents via LDAP en < 5 minutes
  → Détectable via logs LDAP (Event ID 1644 ou logs AD LDS)
Sévérité: MEDIUM
MITRE: T1069.002 — Discovery / Permission Groups Discovery: Domain Groups
```

---

### 2.4 Collection — Groupe fantôme (Shadow Group)

**Scénario** : Création d'un groupe de sécurité en dehors des OU habituelles, avec des accès étendus.

```
RÈGLE: SHADOW-001
Condition:
  group.created
  AND group.distinguishedName NOT STARTS WITH "(OU autorisées connues)"
  AND group.groupType = "security-*"
  AND actor.samAccountName NOT IN (liste comptes autorisés à créer des groupes)
Sévérité: HIGH
MITRE: T1136 — Persistence / Create Account
```

---

### 2.5 Compte orphelin réactivé

**Scénario** : Un compte inactif depuis > 90 jours est soudainement réactivé et ajouté à un groupe.

```
RÈGLE: ORPHAN-001
Condition:
  account.enabled
  AND subject.lastLogon < (now - 90j)  ← enrichissement LDAP
  AND (
    membership.added pour le même sid dans les 30 min
  )
Sévérité: HIGH
MITRE: T1078 — Valid Accounts
```

---

## 3. Dashboard SOC temps réel

### 3.1 Indicateurs clés (KPIs SOC)

```
┌─────────────────────────────────────────────────────────────────┐
│  TABLEAU DE BORD AD — TEMPS RÉEL (rafraîchissement 30s)         │
├──────────────────┬──────────────────┬──────────────────┬────────┤
│ Comptes créés    │ Groupes créés    │ Ajouts groupes   │ Alertes│
│ aujourd'hui      │ aujourd'hui      │ critiques (24h)  │ actives│
│       12         │        3         │        1 🔴      │   2 🔴 │
├──────────────────┴──────────────────┴──────────────────┴────────┤
│                                                                  │
│  Activité par heure (00h-23h)                                   │
│  ████░░░░░░░░░████████░░░░░░░░░░░░ Créations compte             │
│  ██░░░░░░░░░░░███████░░░░░░░░░░░░░ Modifications groupe         │
│                                                                  │
│  TOP 5 Acteurs (dernières 24h)                                  │
│  1. svc-provisioning  → 45 opérations (normal)                  │
│  2. admin.jean.dupont → 12 opérations (normal)                  │
│  3. compromise-user   → 8 opérations  ⚠️ HORS HEURES            │
│                                                                  │
│  Alertes récentes                                               │
│  🔴 [02:17] compromise-user → Domain Admins (HORS HEURES)       │
│  🟠 [08:43] Nouveau groupe hors OU standard: CN=shadow,...      │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 Requêtes Splunk / Elastic prêtes à l'emploi

**Splunk — Ajouts à groupes critiques (dernières 24h)**
```spl
index=ad_iam sourcetype=kafka
type="com.example.ad.membership.added"
data.group.sensitivityLevel IN ("HIGH", "CRITICAL")
| eval actor=data.actor.upn
| eval member=data.member.upn
| eval group=data.group.samAccountName
| table _time, actor, member, group, data.isOutsideBusinessHours
| sort -_time
```

**Elastic KQL — Alertes critiques non acquittées**
```
type: "com.example.ad.alert" AND data.severity: "CRITICAL" AND NOT tags: "acknowledged"
```

---

## 4. Intégration SIEM

### 4.1 Via Kafka Connect (recommandé)

```json
{
  "name": "splunk-sink-iam-alert",
  "config": {
    "connector.class": "com.splunk.kafka.connect.SplunkSinkConnector",
    "tasks.max": "2",
    "topics": "ad.iam.alert,ad.iam.identity,ad.iam.group",
    "splunk.hec.uri": "https://splunk-hec.corp.internal:8088",
    "splunk.hec.token": "${file:/etc/kafka/connect/secrets.properties:splunk.hec.token}",
    "splunk.hec.ssl.validate.certs": "true",
    "splunk.hec.json.event.formatted": "true",
    "splunk.indexes": "ad_iam_alert,ad_iam_identity,ad_iam_group"
  }
}
```

### 4.2 Via Logstash (Elastic)

```ruby
input {
  kafka {
    bootstrap_servers => "kafka-1:9092,kafka-2:9092"
    topics => ["ad.iam.alert", "ad.iam.identity", "ad.iam.group"]
    group_id => "logstash-soc-consumer"
    codec => json
    security_protocol => "SSL"
    ssl_truststore_location => "/etc/logstash/ssl/truststore.jks"
  }
}

filter {
  date {
    match => ["[time]", "ISO8601"]
    target => "@timestamp"
  }
  mutate {
    add_field => { "[@metadata][index_suffix]" => "%{[type]}" }
  }
}

output {
  elasticsearch {
    hosts => ["https://elastic:9200"]
    index => "ad-iam-%{[@metadata][index_suffix]}-%{+YYYY.MM.dd}"
    ssl_certificate_verification => true
    api_key => "${ELASTIC_API_KEY}"
  }
}
```

---

## 5. SOAR — Playbooks automatisés

### Playbook PB-001 : Ajout non autorisé à groupe critique

```yaml
name: "AD - Unauthorized Privileged Group Add"
trigger:
  topic: ad.iam.alert
  filter: "severity == CRITICAL AND ruleId == RULE-001"

steps:
  1_check_change_request:
    action: servicenow.query_change
    params:
      assignment_group: "IAM Team"
      state: "approved"
      subject_user: "{{ event.data.member.upn }}"
    on_found: CLOSE_FALSE_POSITIVE
    on_not_found: CONTINUE

  2_disable_account:
    action: activedirectory.disable_account
    params:
      samAccountName: "{{ event.data.member.samAccountName }}"
    on_failure: ALERT_HUMAN

  3_remove_from_group:
    action: activedirectory.remove_from_group
    params:
      member: "{{ event.data.member.samAccountName }}"
      group: "{{ event.data.group.samAccountName }}"
    on_failure: ALERT_HUMAN

  4_create_incident:
    action: servicenow.create_incident
    params:
      priority: P1
      category: "Security Incident"
      description: "Unauthorized privilege escalation detected"
      assignment_group: "SOC Team"
      evidence: "{{ event | tojson }}"

  5_notify_manager:
    action: email.send
    params:
      to: "{{ event.data.member.manager }}"
      subject: "Security Alert: Account {{ event.data.member.upn }} suspended"
      template: "account-suspension-manager"

  6_publish_audit:
    action: kafka.produce
    params:
      topic: ad.audit.trail
      message: "{{ playbook_execution_summary | tojson }}"
```

---

## 6. Métriques SOC

| Métrique | Définition | Objectif |
|---|---|---|
| **MTTD** (Mean Time To Detect) | Temps entre le changement AD et la génération d'alerte SOC | < 60 secondes |
| **MTTR** (Mean Time To Respond) | Temps entre l'alerte et la réponse (playbook complet) | < 5 minutes (automatisé) |
| **False Positive Rate** | % d'alertes qui ne sont pas de vraies menaces | < 10% |
| **Coverage** | % des Event IDs critiques couverts par au moins une règle | 100% pour CRITICAL |
| **Alert Fatigue Index** | Alertes / analyste / jour | < 20 |
