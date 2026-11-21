# Contribuer à arc-docs

Merci de l'intérêt porté à cette documentation. Corrections, précisions et nouveaux guides sont les bienvenus.

## Avant de commencer

- Pour un changement important, ouvrir d'abord une *issue*.
- Pour une faille de sécurité, ne pas ouvrir d'*issue* publique : suivre [SECURITY.md](SECURITY.md).

## Proposer un changement

1. Forker le dépôt et créer une branche dédiée (`docs/...`).
2. Rédiger en français, avec des valeurs d'exemple fictives (domaine `example`), sans secret ni donnée d'environnement réel.
3. Utiliser des messages de commit au format [Conventional Commits](https://www.conventionalcommits.org/fr/) (`docs:`, `fix:`...).
4. Ouvrir une *pull request* vers la branche `main`.

## Licence et conformité

La documentation est distribuée sous licence [CC-BY-4.0](LICENSES/CC-BY-4.0.txt) et les scripts d'exemple (`docs/annexes/`) sous [EUPL-1.2](LICENSE). Le dépôt respecte la spécification [REUSE](https://reuse.software/) : `pip install reuse` puis `reuse lint`.

## Certificat d'origine (DCO)

En soumettant une contribution, vous certifiez, au sens du [Developer Certificate of Origin](https://developercertificate.org/), avoir le droit de la proposer sous la licence du fichier concerné. Chaque commit doit comporter la mention `Signed-off-by` :

```bash
git commit -s -m "docs: corrige ..."
```

## Code de conduite

Voir [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
