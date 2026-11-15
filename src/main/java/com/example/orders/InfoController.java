package com.example.orders;

import java.util.Map;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Dit quel pod a répondu, avec quelle version et quelle configuration.
 *
 * <p>Dans Kubernetes, le nom d'hôte d'un conteneur est le nom de son pod : c'est ce qui permet de voir le Service
 * répartir les requêtes, et la mise à jour remplacer les pods un par un.
 */
@RestController
class InfoController {

    private final String pod;
    private final String version;
    private final String message;

    InfoController(@Value("${HOSTNAME:local}") String pod, @Value("${app.version}") String version,
            @Value("${app.message}") String message) {
        this.pod = pod;
        this.version = version;
        this.message = message;
    }

    @GetMapping("/info")
    Map<String, String> info() {
        return Map.of("pod", pod, "version", version, "message", message);
    }
}
