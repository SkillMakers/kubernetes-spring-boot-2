package com.example.orders;

import java.util.List;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * La seule route qui utilise la base : la liste des commandes.
 *
 * <p>Dans la vidéo, c'est elle qui échoue quand la base est figée, alors que {@code /info} continue de répondre.
 */
@RestController
class OrderController {

    private final OrderRepository repository;

    OrderController(OrderRepository repository) {
        this.repository = repository;
    }

    @GetMapping({"/orders", "/commandes"})
    List<PurchaseOrder> all() {
        return repository.findAll();
    }
}
