# Spring Boot sur Kubernetes : probes, mémoire de la JVM, arrêt propre et autoscaling

Code de la 2e vidéo de la série **Kubernetes pour développeurs Java** de la chaîne
[IT Skills Maker](https://www.youtube.com/@ItSkillsMaker). La 1re vidéo et son code :
[SkillMakers/kubernetes-spring-boot](https://github.com/SkillMakers/kubernetes-spring-boot).

La même application de commandes (Spring Boot 4.1, Java 25, PostgreSQL), sur un vrai cluster Kubernetes local, et
quatre pièges de Java provoqués puis corrigés. Chaque sortie de la vidéo vient de [`preuves/`](preuves/).

## Lancer

Il faut Docker, [kind](https://kind.sigs.k8s.io/) et kubectl.

```
./mvnw package
docker build -t orders:3.0 .
kind create cluster --name demo --config kind-cluster.yaml
bash demo.sh
```

`demo.sh` charge l'image, installe metrics-server, joue chaque scénario et réécrit `preuves/`. Il passe par le kubectl
du nœud (`docker exec demo-control-plane kubectl`), pour avoir la même version que le cluster. Le tout prend ~45 min ;
`ETAPE=depart|memoire|sondes|arret|hpa bash demo.sh` rejoue une seule partie.

Pour tout supprimer : `kind delete cluster --name demo`.

## Le manifeste final

[`k8s/orders-production.yaml`](k8s/orders-production.yaml), avec [`k8s/hpa.yaml`](k8s/hpa.yaml) :

- **mémoire** : `-XX:MaxRAMPercentage=50 -XX:+ExitOnOutOfMemoryError` sur une limite de 512 Mi ;
- **probes** : startup (jusqu'à 120 s pour démarrer), liveness sur `/actuator/health/liveness` (jamais sur la base),
  readiness sur `/actuator/health/readiness` ;
- **arrêt** : `preStop` `sleep` de 5 s (natif depuis Kubernetes 1.32, sans shell dans l'image), et
  `terminationGracePeriodSeconds: 40` (5 s de preStop + 30 s d'arrêt propre de Spring Boot + marge) ;
- **autoscaling** : `requests.cpu` renseigné, et plus de `replicas` dans le Deployment.

## Les fichiers

| Fichier | Rôle |
|---|---|
| `k8s/orders.yaml` | point de départ : l'appli de la vidéo 1 avec sa readiness probe, sans réglage mémoire, sans liveness, sans arrêt propre |
| `k8s/liveness-impatiente.yaml` | piège : liveness sans startup probe |
| `k8s/startup-probe.yaml` | correction : startup probe |
| `k8s/liveness-base.yaml` | piège : liveness sur `/actuator/health`, qui inclut la base |
| `k8s/liveness.yaml` | correction : liveness sur `/actuator/health/liveness` |
| `k8s/prestop.yaml` | correction de l'arrêt : `preStop` `sleep` 5 s |
| `k8s/hpa.yaml` | HorizontalPodAutoscaler : 2 à 6 copies, 60 % du processeur demandé |
| `k8s/metrics-server.yaml` | metrics-server v0.9.1, avec `--kubelet-insecure-tls` pour kind |
| `k8s/orders-production.yaml` | tout corrigé |
| `src/…/DemoController.java` | adresses de démonstration : `/jvm`, `/memoire?mo=`, `/calcul`, `/lent?s=` (à ne pas garder en production) |

## Les preuves

Kubernetes 1.37.0 (kind v0.33.0, un nœud), Docker Desktop 29.3.1, le 15/11/2026.

| Fichier | Ce qu'il montre |
|---|---|
| `01-memoire-au-demarrage.txt` | au repos : 33 Mo utilisés dans le tas, 213 Mo occupés par le conteneur |
| `02-jvm-par-defaut.txt` | sans option : tas de 123 Mo sur 512 Mi ; `OutOfMemoryError`, et le pod reste `Running`, 0 redémarrage, muet |
| `03-xmx-egal-limite.txt` | `-Xmx512m` : tué par le noyau (code 137) après 250 Mo retenus |
| `04-ram-75-pourcent.txt` | `MaxRAMPercentage=75` à 512 Mi : tué par le noyau après 280 Mo |
| `05-ram-50-pourcent.txt` | 50 % + `ExitOnOutOfMemoryError` : la JVM s'arrête d'elle-même (code 3) et repart |
| `06-ram-75-pourcent-1Gi.txt` | 75 % sur une limite de 1 Gi : passe, la JVM s'arrête d'elle-même (code 3) |
| `07-liveness-impatiente.txt` | liveness sans startup probe : CrashLoopBackOff, mise à jour bloquée |
| `08-startup-probe.txt` | avec startup probe : mise à jour terminée, 0 redémarrage |
| `09-liveness-sur-la-base.txt` | base figée, liveness sur `/actuator/health` : les 3 pods en CrashLoopBackOff, plus rien ne répond |
| `10-liveness-correcte.txt` | base figée, liveness correcte : 0 redémarrage, `/info` répond, la base revient sans intervention |
| `11-arret-sans-prestop.txt` | 3 mises à jour sous charge : 11, 13, 14 erreurs |
| `12-arret-avec-prestop.txt` | les mêmes avec `preStop` : 0, 0, 0 |
| `13-requete-longue.txt` | requête de 20 s terminée pendant l'arrêt ; requête de 45 s coupée au bout du délai par défaut de 30 s (le manifeste final le porte à 40 s) |
| `14-hpa-sans-request.txt` | HPA sans `requests.cpu` : `<unknown>`, aucune action |
| `15-retirer-replicas.txt` | retirer `replicas` du manifeste : le Deployment tombe à 1 copie |
| `16-hpa.txt` | montée de 3 à 6 copies en moins d'une minute sous charge, descente à 2 au bout de 5 min 48 |
| `17-replicas-et-hpa.txt` | `replicas: 3` réappliqué à 6 copies : 3 pods arrêtés en pleine charge, 32 s pour revenir à 6 |

## Ce que la démo simplifie

- **Un seul nœud**, et les mêmes réserves que la vidéo 1 : PostgreSQL sans volume, `ddl-auto=update`, Secret créé en
  ligne de commande.
- **La base est « figée »** (`pkill -STOP -x postgres` depuis le nœud) pour simuler une panne sans perdre ses données.
- **Le code 137 s'affiche avec le motif « Error »**, et pas « OOMKilled » : la VM de Docker Desktop tourne en cgroup v1.
  Le noyau confirme le manque de mémoire (ligne `dmesg` dans `03` et `04`).
- **La liveness passe par le même Tomcat que le trafic.** La démo n'envoie qu'une requête pendant la panne de la base.
  Sous forte charge, des requêtes bloquées sur la base peuvent occuper tous les threads et faire expirer la liveness :
  prévoir un `timeoutSeconds` plus large, ou un port de gestion séparé (`management.server.port`).
- **Au démarrage, la JVM consomme beaucoup de processeur** (compilation, chargement des classes). Une fois le pod prêt,
  ce pic compte pour l'autoscaler et peut ajouter une copie sans trafic : voir `behavior.scaleUp` dans la doc de l'HPA,
  ou une demande de processeur plus large.
- **Les seuils mémoire valent pour cette application** : de 180 à 270 Mo hors des données selon les mesures, d'où la règle : au moins 250 Mo hors du tas. Mesurez la vôtre
  (mémoire du pod sous charge, pas seulement le tas).
