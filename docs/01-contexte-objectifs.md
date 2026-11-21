# 01 — Contexte et Objectifs

## 1. Contexte métier

Active Directory (AD) reste le **référentiel d'identités central** dans la quasi-totalité des entreprises du secteur privé et public. Il concentre :

- Les **comptes utilisateurs** (employés, prestataires, comptes de service)
- Les **groupes de sécurité** (contrôle d'accès aux ressources)
- Les **objets machines** et stratégies de groupe (GPO)

Toute modification dans AD a des **implications de sécurité immédiates** (escalade de privilèges, création de backdoor) et des **impacts opérationnels** (provisioning, déprovisioning, synchronisation avec des systèmes tiers).

Aujourd'hui, ces changements sont :
- Mal journalisés ou journalisés de façon disparate selon les Domain Controllers
- Peu ou pas consommés en temps réel
- Difficilement traçables a posteriori pour le SOC
- Propagés vers les systèmes tiers en mode **batch nocturne** (synchronisation LDAP full, exports CSV…)

---

## 2. Problèmes adressés

### 2.1 Sécurité — SOC

| Problème | Impact |
|---|---|
| Création de compte admin non justifiée | Compromission potentielle non détectée |
| Ajout d'un compte à un groupe privilégié (Domain Admins, Enterprise Admins) | Escalade de privilèges silencieuse |
| Création de groupe fantôme | Contournement des politiques d'accès |
| Comptes orphelins actifs | Surface d'attaque inutile |

Sans détection en temps-réel, la fenêtre entre l'action malveillante et sa détection peut atteindre **plusieurs jours voire semaines**.

### 2.2 Synchronisation — Opérations

| Problème | Impact |
|---|---|
| Synchronisation batch toutes les 24h | Décalage d'accès (onboarding lent, offboarding risqué) |
| Couplage fort entre AD et les systèmes cibles | Fragilité, maintenabilité difficile |
| Absence de log des changements propagés | Auditabilité nulle |
| Absence de rejeu en cas d'échec | Perte de synchronisation silencieuse |

---

## 3. Objectifs du système

### Objectif principal
> Capturer **en quasi-temps-réel** tout changement d'identité dans Active Directory, le **normaliser** sous forme d'événement structuré, et le **publier** dans un bus de messages accessible aux consommateurs SOC et de synchronisation.

### Objectifs secondaires

1. **Indépendance** : les consommateurs ne doivent pas dépendre d'AD directement.
2. **Auditabilité** : chaque événement doit être traçable (qui a fait quoi, quand, depuis où).
3. **Extensibilité** : le système doit pouvoir intégrer d'autres annuaires (Azure AD / Entra ID, LDAP OpenLDAP, Google Workspace).
4. **Résilience** : perte momentanée d'un Domain Controller ne doit pas créer de trou de collecte.
5. **Idempotence** : un événement rejoué ne doit pas créer d'effet de bord chez les consommateurs.

---

## 4. Parties prenantes

| Partie prenante | Rôle | Intérêt |
|---|---|---|
| Équipe SOC | Consommateur | Détection de menaces, réponse aux incidents |
| Équipe IAM | Consommateur / Producteur | Synchronisation des accès |
| Équipe Infra / AD | Producteur | Maintien de l'annuaire source |
| Équipe Architecture | Pilotage | Cohérence et gouvernance technique |
| DPO / RSSI | Supervision | Conformité RGPD, traçabilité des accès |
| ITSM (ServiceNow…) | Consommateur | Ticket automatique sur changement d'accès |

---

## 5. Périmètre v1

### Inclus
- Windows Active Directory (on-premise), tous Domain Controllers du domaine
- Événements : création/suppression de comptes, activation/désactivation, création/suppression de groupes, ajout/retrait de membres
- Publication dans un topic Kafka (ou équivalent)
- Au moins deux consommateurs : SOC (SIEM) et synchronisation IAM

### Hors périmètre v1
- Azure AD / Entra ID (roadmap v2)
- Modifications d'objets machines ou GPO
- Authentifications (Kerberos, NTLM) — sauf si nécessaire SOC
- Gestion des mots de passe (Event ID 4723, 4724)

---

## 6. Contraintes

| Contrainte | Type | Description |
|---|---|---|
| Latence max | Performance | < 30 secondes du changement AD à la publication dans le topic |
| Volume | Performance | Jusqu'à 10 000 événements/heure en pic (grande entreprise) |
| Rétention des événements | Durabilité | 90 jours minimum (exigence audit) |
| Chiffrement | Sécurité | TLS obligatoire sur tous les flux, données sensibles masquées |
| Conformité RGPD | Légal | Pas de données personnelles brutes dans les logs de debug |
| Haute disponibilité | Résilience | RTO < 5 min, RPO = 0 (aucune perte d'événement) |
