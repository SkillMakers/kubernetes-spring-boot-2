package com.example.orders;

import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.math.BigDecimal;

/** Une commande, stockée dans la table {@code orders} de PostgreSQL (schéma créé par Hibernate au démarrage). */
@Entity
@Table(name = "orders")
public class PurchaseOrder {

    @Id
    @GeneratedValue
    Long id;

    String customer;

    BigDecimal total;

    public Long getId() {
        return id;
    }

    public String getCustomer() {
        return customer;
    }

    public BigDecimal getTotal() {
        return total;
    }
}
