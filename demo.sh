#!/usr/bin/env bash
# Joue chaque scénario de la vidéo 2 sur le cluster kind « demo » et écrit les sorties dans preuves/.
# Prérequis : Docker, kind, le cluster (`kind create cluster --name demo --config kind-cluster.yaml`) et l'image
# (`./mvnw package` puis `docker build -t orders:3.0 .`). Durée : ~45 min.
# `ETAPE=depart|memoire|sondes|arret|hpa bash demo.sh` rejoue une seule partie (les parties suivantes supposent les
# précédentes jouées au moins une fois : base, Secret, client, metrics-server).
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash sous Windows : ne pas réécrire les chemins /tmp/... passés au cluster
cd "$(dirname "$0")"
ETAPE=${ETAPE:-tout}
partie() { [ "$ETAPE" = tout ] || [ "$ETAPE" = "$1" ]; }

# kubectl du nœud de contrôle : même version que le cluster.
k() { docker exec -i demo-control-plane kubectl "$@"; }
run() { echo "\$ kubectl $*"; k "$@" 2>&1 || true; echo; }
dans_client() { k exec client -- sh -c "$1"; }
maintenant() { date +%s; }
# Pods de l'appli qui ne sont pas en cours d'arrêt, du plus ancien au plus récent : nom, redémarrages, motif et code
# du dernier arrêt.
etat_pods() {
  k get pods -l app=orders --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"|"}{.metadata.name}{"  prêt="}{.status.containerStatuses[0].ready}{"  redémarrages="}{.status.containerStatuses[0].restartCount}{"  dernier arrêt : "}{.status.containerStatuses[0].lastState.terminated.reason}{" code "}{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}{end}' \
    | awk -F'|' '$1=="" {print $2}'
}
pret() { k rollout status deployment/orders --timeout=400s >/dev/null; sleep 3; }
# Remplit la mémoire de l'appli par blocs, jusqu'à ce qu'elle ne réponde plus.
remplir() {
  local pas=$1
  for i in $(seq 1 20); do
    echo "\$ curl -s http://orders/memoire?mo=$pas"
    if ! dans_client "curl -s -m 30 -w '  HTTP %{http_code}\n' http://orders/memoire?mo=$pas"; then
      echo "  (pas de réponse : la connexion a été coupée)"; break
    fi
  done
  echo
}
# Horloge du noyau (secondes depuis le démarrage de la VM) : c'est elle qui date les lignes de dmesg.
horloge_noyau() { docker exec demo-control-plane cut -d' ' -f1 /proc/uptime; }
# Lignes du noyau datées après $1 : un processus java tué faute de mémoire pendant l'essai.
noyau_oom() {
  local lignes
  lignes=$(docker exec demo-control-plane dmesg | grep "Killed process" | grep java     | awk -v debut="$1" '{t=$0; sub(/^\[ */, "", t); sub(/\].*/, "", t); if (t+0 > debut+0) print}' || true)
  if [ -n "$lignes" ]; then echo "$lignes"; else echo "(aucune : le noyau n'a rien tué)"; fi
}
# Charge régulière sur /info : 3 boucles, une requête toutes les 0,1 s chacune.
lancer_charge() {
  dans_client 'rm -f /tmp/r1 /tmp/r2 /tmp/r3 /tmp/stop; for n in 1 2 3; do nohup sh -c "while [ ! -f /tmp/stop ]; do curl -s -o /dev/null -m 2 -w \"%{http_code}\n\" http://orders/info >> /tmp/r$n; sleep 0.1; done" >/dev/null 2>&1 & done'
}
arreter_charge() { dans_client 'touch /tmp/stop'; sleep 3; dans_client 'cat /tmp/r1 /tmp/r2 /tmp/r3 | sort | uniq -c'; }
# Charge de calcul pour l'autoscaling : 3 boucles sans pause sur /calcul (~50 ms de processeur par requête).
lancer_calcul() { dans_client 'rm -f /tmp/stop; for n in 1 2 3; do nohup sh -c "while [ ! -f /tmp/stop ]; do curl -s -o /dev/null -m 5 http://orders/calcul; done" >/dev/null 2>&1 & done'; }
arreter_calcul() { dans_client 'touch /tmp/stop'; }
# La base ne répond plus, sans perdre ses données : ses processus sont gelés (SIGSTOP) depuis le nœud, comme une
# machine figée. Changer le Service ne suffit pas : les connexions déjà ouvertes continuent de passer.
couper_base() { docker exec demo-control-plane pkill -STOP -x postgres; }
retablir_base() { docker exec demo-control-plane pkill -CONT -x postgres; }
# Pod de l'appli le plus récent parmi ceux qui ne sont pas en cours d'arrêt.
pod_actif() { etat_pods | tail -1 | awk '{print $1}'; }

if [ "$ETAPE" = tout ]; then
  echo "== Préparation"
  kind load docker-image orders:3.0 --name demo >/dev/null
  k delete hpa orders --ignore-not-found >/dev/null
  k delete deployment orders --ignore-not-found >/dev/null
  if ! k get secret orders-db >/dev/null 2>&1; then
    k create secret generic orders-db --from-literal=password=Sup3r-Secret >/dev/null
  fi
  k apply -f - < k8s/postgres.yaml >/dev/null
  k rollout status deployment/postgres --timeout=300s >/dev/null
  if [ "$(k get pod client -o jsonpath='{.status.phase}' 2>/dev/null)" != Running ]; then
    k delete pod client --ignore-not-found --now >/dev/null
    k run client --image=curlimages/curl:8.17.0 --restart=Never --command -- sleep infinity >/dev/null
    k wait --for=condition=Ready pod/client --timeout=200s >/dev/null
  fi
  k apply -f - < k8s/metrics-server.yaml >/dev/null
  { run version; run get nodes; } > preuves/00-cluster.txt
fi

if partie depart; then
  echo "== 0. Mémoire d'une application qui vient de démarrer"
  k delete hpa orders --ignore-not-found >/dev/null
  k delete deployment orders --ignore-not-found >/dev/null
  k apply -f - < k8s/orders.yaml >/dev/null
  k scale deployment orders --replicas=1 >/dev/null; pret; sleep 20
  p=$(pod_actif)
  {
    echo "# Application démarrée, aucune requête. Le tas, vu par la JVM :"
    echo "\$ curl -s http://orders/jvm"; dans_client 'curl -s http://orders/jvm'; echo; echo
    # cgroup v1 (cette VM) : total_rss, la mémoire anonyme du conteneur. En cgroup v2, memory.current compte aussi le
    # cache de fichiers : la valeur serait plus haute.
    echo "# La mémoire réellement occupée par le conteneur (groupe de contrôle du pod) :"
    echo "\$ kubectl exec $p -- sh -c 'cat /sys/fs/cgroup/memory.current 2>/dev/null || grep -w total_rss /sys/fs/cgroup/memory/memory.stat'"
    k exec "$p" -- sh -c 'cat /sys/fs/cgroup/memory.current 2>/dev/null || grep -w total_rss /sys/fs/cgroup/memory/memory.stat' \
      | awk '{printf "%s  (%.0f Mo)\n", $0, $NF/1048576}'
  } > preuves/01-memoire-au-demarrage.txt
fi

if partie memoire; then
  echo "== 1. Mémoire de la JVM"
  k delete hpa orders --ignore-not-found >/dev/null
  k delete deployment orders --ignore-not-found >/dev/null
  k apply -f - < k8s/orders.yaml >/dev/null
  k scale deployment orders --replicas=1 >/dev/null; pret
  {
    echo "# Limite du conteneur : 512 Mi. Aucune option mémoire donnée à la JVM."
    echo "\$ curl -s http://orders/jvm"; dans_client 'curl -s http://orders/jvm'; echo; echo
    remplir 50
    echo "# Une minute plus tard :"
    sleep 60
    run get pods -l app=orders
    etat_pods; echo
    echo "\$ kubectl logs -l app=orders | grep -o 'java.lang.OutOfMemoryError.*' | head -1"
    k logs -l app=orders --tail=500 | grep -o -m1 "java.lang.OutOfMemoryError.*" | cut -c1-120 || true; echo
    echo "\$ curl -s -m 5 http://orders/info"
    dans_client 'curl -s -m 5 -w "HTTP %{http_code}\n" http://orders/info' || echo "(pas de réponse)"
  } > preuves/02-jvm-par-defaut.txt

  for essai in "03-xmx-egal-limite|-Xmx512m|512Mi|50" \
               "04-ram-75-pourcent|-XX:MaxRAMPercentage=75|512Mi|40" \
               "05-ram-50-pourcent|-XX:MaxRAMPercentage=50 -XX:+ExitOnOutOfMemoryError|512Mi|40" \
               "06-ram-75-pourcent-1Gi|-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError|1Gi|80"; do
    IFS='|' read -r fichier options limite pas <<< "$essai"
    k set env deployment/orders "JAVA_TOOL_OPTIONS=$options" >/dev/null
    k set resources deployment/orders --limits=memory="$limite" >/dev/null
    pret
    avant=$(horloge_noyau)
    {
      echo "# Limite du conteneur : $limite. JAVA_TOOL_OPTIONS=$options"
      echo "\$ curl -s http://orders/jvm"; dans_client 'curl -s http://orders/jvm'; echo; echo
      remplir "$pas"
      sleep 5
      echo "# Après l'arrêt :"
      etat_pods; echo
      p=$(pod_actif)
      echo "\$ kubectl logs $p --previous | tail -1"
      k logs "$p" --previous --tail=1 2>&1 | cut -c1-160 || true; echo
      echo "# Ce que le noyau a tué faute de mémoire pendant cet essai (dmesg) :"
      noyau_oom "$avant"
    } > "preuves/$fichier.txt"
  done
  k set resources deployment/orders --limits=memory=512Mi >/dev/null
fi

if partie sondes; then
  echo "== 2. Probes"
  k delete hpa orders --ignore-not-found >/dev/null
  k delete deployment orders --ignore-not-found >/dev/null
  k apply -f - < k8s/orders.yaml >/dev/null
  k set env deployment/orders "JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=50 -XX:+ExitOnOutOfMemoryError" >/dev/null
  pret
  {
    echo "\$ kubectl patch deployment orders --patch-file k8s/liveness-impatiente.yaml"
    k patch deployment orders --patch "$(cat k8s/liveness-impatiente.yaml)"; echo
    sleep 150
    echo "# 2 min 30 plus tard :"
    run get pods -l app=orders
    echo "\$ kubectl get events | grep orders | grep -i liveness | tail -2"
    k get events --sort-by=.lastTimestamp | grep orders | grep -i liveness | tail -2 | cut -c1-200 || true; echo
    echo "\$ kubectl rollout status deployment/orders --timeout=5s"
    k rollout status deployment/orders --timeout=5s 2>&1 | tail -1 || true
  } > preuves/07-liveness-impatiente.txt

  {
    echo "\$ kubectl patch deployment orders --patch-file k8s/startup-probe.yaml"
    k patch deployment orders --patch "$(cat k8s/startup-probe.yaml)"; echo
    debut=$(maintenant); pret; fin=$(maintenant)
    echo "# Mise à jour terminée en $((fin - debut)) s."
    run get pods -l app=orders
  } > preuves/08-startup-probe.txt

  {
    echo "\$ kubectl patch deployment orders --patch-file k8s/liveness-base.yaml"
    k patch deployment orders --patch "$(cat k8s/liveness-base.yaml)"; echo
    pret
    run get pods -l app=orders
    echo "# La base ne répond plus (ses processus sont gelés)."
    couper_base; sleep 90
    echo "# 90 s plus tard :"
    run get pods -l app=orders
    echo "\$ curl -s -m 5 http://orders/info   # n'utilise pas la base"
    dans_client 'curl -s -m 5 -w "HTTP %{http_code}\n" http://orders/info' || echo "(pas de réponse)"
    retablir_base
  } > preuves/09-liveness-sur-la-base.txt
  # Remettre l'appli d'aplomb : la base revient, les pods finissent par redémarrer.
  k patch deployment orders --patch "$(cat k8s/liveness.yaml)" >/dev/null
  k rollout restart deployment/orders >/dev/null; pret

  {
    echo "\$ kubectl patch deployment orders --patch-file k8s/liveness.yaml"
    echo "# (déjà appliqué, application redémarrée)"
    run get pods -l app=orders
    echo "# La base ne répond plus."
    couper_base; sleep 90
    echo "# 90 s plus tard :"
    run get pods -l app=orders
    for u in actuator/health/liveness actuator/health/readiness info commandes; do
      echo "\$ curl -s -m 5 http://orders/$u"
      dans_client "curl -s -m 5 -o /dev/null -w 'HTTP %{http_code}\n' http://orders/$u" || echo "(pas de réponse en 5 s)"
    done
    echo
    retablir_base; sleep 10
    echo "# La base revient :"
    echo "\$ curl -s http://orders/commandes"
    dans_client 'curl -s -m 10 -w "  HTTP %{http_code}\n" http://orders/commandes' || true
  } > preuves/10-liveness-correcte.txt
fi

if partie arret; then
  echo "== 3. Arrêt propre"
  # Partir d'un état connu : pas d'autoscaler qui changerait le nombre de copies pendant les mises à jour.
  k delete hpa orders --ignore-not-found >/dev/null
  k scale deployment orders --replicas=3 >/dev/null
  k patch deployment orders --type=json -p='[{"op":"remove","path":"/spec/template/spec/containers/0/lifecycle"}]' >/dev/null 2>&1 || true
  pret
  {
    echo "# Sans preStop : 3 mises à jour (rollout restart), avec des requêtes en continu."
    for n in 1 2 3; do
      lancer_charge; sleep 3
      k rollout restart deployment/orders >/dev/null; pret; sleep 2
      echo "# Mise à jour $n :"; arreter_charge
    done
  } > preuves/11-arret-sans-prestop.txt

  echo "\$ kubectl patch deployment orders --patch-file k8s/prestop.yaml" > preuves/12-arret-avec-prestop.txt
  k patch deployment orders --patch "$(cat k8s/prestop.yaml)" >/dev/null; pret
  {
    echo "# Avec preStop : les 3 mêmes mises à jour."
    for n in 1 2 3; do
      lancer_charge; sleep 3
      k rollout restart deployment/orders >/dev/null; pret; sleep 2
      echo "# Mise à jour $n :"; arreter_charge
    done
  } >> preuves/12-arret-avec-prestop.txt

  {
    for s in 20 45; do
      victime=$(k get pods -l app=orders -o jsonpath='{.items[0].metadata.name}')
      ip=$(k get pod "$victime" -o jsonpath='{.status.podIP}')
      echo "# Une requête de $s s envoyée au pod $victime, qu'on arrête 2 s plus tard :"
      dans_client "rm -f /tmp/lent; (curl -s -m 90 -w '  HTTP %{http_code} au bout de %{time_total} s' http://$ip:8080/lent?s=$s > /tmp/lent 2>&1 &)"
      sleep 2
      echo "\$ kubectl delete pod $victime"
      debut=$(maintenant); k delete pod "$victime"; fin=$(maintenant)
      sleep 3
      echo "\$ cat /tmp/lent"; dans_client 'cat /tmp/lent'; echo
      echo "# Arrêt du pod : $((fin - debut)) s."; echo
      pret
    done
  } > preuves/13-requete-longue.txt
fi

if partie hpa; then
  echo "== 4. Autoscaling"
  k delete hpa orders --ignore-not-found >/dev/null
  k -n kube-system rollout status deployment/metrics-server --timeout=300s >/dev/null
  {
    echo "# Le Deployment ne demande pas de processeur (pas de resources.requests.cpu) :"
    k patch deployment orders --type=json -p='[{"op":"remove","path":"/spec/template/spec/containers/0/resources/requests/cpu"}]' >/dev/null
    pret
    echo "\$ kubectl apply -f k8s/hpa.yaml"; k apply -f - < k8s/hpa.yaml; echo
    sleep 75
    run get hpa orders
    echo "\$ kubectl describe hpa orders | grep ScalingActive"
    k describe hpa orders | grep ScalingActive | cut -c1-200 || true
  } > preuves/14-hpa-sans-request.txt

  {
    echo "# Le manifeste final (requests.cpu remis, et plus de « replicas » : l'HPA décide) :"
    run get deployment orders
    echo "\$ kubectl apply -f k8s/orders-production.yaml"; k apply -f - < k8s/orders-production.yaml; echo
    debut=$(maintenant)
    for i in $(seq 1 12); do
      echo "$(( $(maintenant) - debut )) s  voulues=$(k get deploy orders -o jsonpath='{.spec.replicas}')  prêtes=$(k get deploy orders -o jsonpath='{.status.readyReplicas}')"
      sleep 5
    done
  } > preuves/15-retirer-replicas.txt
  pret

  {
    sleep 60
    run get hpa orders
    echo "# Charge de calcul : 3 boucles de requêtes sur /calcul. Relevé toutes les 5 s :"
    lancer_calcul
    debut=$(maintenant)
    while [ $(( $(maintenant) - debut )) -lt 150 ]; do
      echo "$(( $(maintenant) - debut )) s  $(k get hpa orders --no-headers | awk '{print $3, $4, "copies="$7}')  prêtes=$(k get deploy orders -o jsonpath='{.status.readyReplicas}')"
      sleep 5
    done
    arreter_calcul
    echo; echo "# Fin de la charge. Relevé à chaque changement :"
    debut=$(maintenant); avant=""
    while [ $(( $(maintenant) - debut )) -lt 480 ]; do
      ligne="$(k get hpa orders --no-headers | awk '{print $3, $4, "copies="$7}')"
      [ "$ligne" != "$avant" ] && echo "$(( $(maintenant) - debut )) s  $ligne"
      avant=$ligne; sleep 10
    done
  } > preuves/16-hpa.txt

  {
    echo "# Charge de calcul, jusqu'à 6 copies prêtes :"
    lancer_calcul
    debut=$(maintenant)
    until [ "$(k get deploy orders -o jsonpath='{.status.readyReplicas}')" = 6 ]; do
      sleep 3; [ $(( $(maintenant) - debut )) -lt 300 ] || break
    done
    run get deployment orders
    echo "# On réapplique le manifeste, qui contient encore « replicas: 3 » :"
    echo "$ kubectl apply -f k8s/orders-production.yaml   # avec « replicas: 3 » ajouté"
    awk '/^kind: Deployment/{d=1} d && /^spec:$/{print; print "  replicas: 3"; d=0; next} {print}' k8s/orders-production.yaml \
      | k apply -f - | grep deployment
    debut=$(maintenant)
    for i in $(seq 1 14); do
      echo "$(( $(maintenant) - debut )) s  voulues=$(k get deploy orders -o jsonpath='{.spec.replicas}')  prêtes=$(k get deploy orders -o jsonpath='{.status.readyReplicas}')"
      sleep 4
    done
    arreter_calcul
  } > preuves/17-replicas-et-hpa.txt
fi
echo "== Fini"
