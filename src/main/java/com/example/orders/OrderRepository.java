package com.example.orders;

import org.springframework.data.jpa.repository.JpaRepository;

/** Accès aux commandes, fourni par Spring Data JPA. */
public interface OrderRepository extends JpaRepository<PurchaseOrder, Long> {}
