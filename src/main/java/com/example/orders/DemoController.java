package com.example.orders;

import java.lang.management.ManagementFactory;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * Points d'entrée de la démo, pour provoquer ce que la vidéo mesure : de la mémoire retenue, du calcul, une requête
 * longue. À ne pas garder dans une vraie application.
 */
@RestController
class DemoController {

    /** Garde les blocs alloués : sans cette liste, le ramasse-miettes les libérerait aussitôt. */
    private static final List<byte[]> RETENUS = new ArrayList<>();

    /** Ce que la JVM a compris de son conteneur : tas maximal, processeurs vus. */
    @GetMapping("/jvm")
    Map<String, Object> jvm() {
        Runtime rt = Runtime.getRuntime();
        return Map.of(
                "tasMaxMo", rt.maxMemory() / (1024 * 1024),
                "tasUtiliseMo", (rt.totalMemory() - rt.freeMemory()) / (1024 * 1024),
                "processeurs", rt.availableProcessors(),
                "options", ManagementFactory.getRuntimeMXBean().getInputArguments());
    }

    /** Alloue {@code mo} mégaoctets et les garde en mémoire, comme un cache qui grossit. */
    @GetMapping("/memoire")
    synchronized Map<String, Object> memoire(@RequestParam int mo) {
        for (int i = 0; i < mo; i++) {
            byte[] bloc = new byte[1024 * 1024];
            // Écrire dans chaque page : sinon le système ne réserve pas vraiment la mémoire.
            for (int j = 0; j < bloc.length; j += 4096) {
                bloc[j] = 1;
            }
            RETENUS.add(bloc);
        }
        return Map.of("retenusMo", RETENUS.size());
    }

    /** Environ 50 ms de calcul pur, pour charger le processeur pendant la démo d'autoscaling. */
    @GetMapping("/calcul")
    Map<String, Object> calcul() throws NoSuchAlgorithmException {
        MessageDigest sha = MessageDigest.getInstance("SHA-256");
        byte[] h = new byte[32];
        long fin = System.nanoTime() + 50_000_000L;
        long tours = 0;
        while (System.nanoTime() < fin) {
            h = sha.digest(h);
            tours++;
        }
        return Map.of("tours", tours);
    }

    /** Répond au bout de {@code s} secondes : une requête encore en cours quand le pod reçoit l'ordre de s'arrêter. */
    @GetMapping("/lent")
    Map<String, Object> lent(@RequestParam int s) throws InterruptedException {
        Thread.sleep(s * 1000L);
        return Map.of("fini", true, "pod", System.getenv().getOrDefault("HOSTNAME", "local"));
    }
}
