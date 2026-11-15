package com.example.orders;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(InfoController.class)
@TestPropertySource(properties = {"app.version=2", "app.message=Salut"})
class InfoControllerTest {

    @Autowired
    MockMvc mvc;

    @Test
    @DisplayName("/info renvoie le nom du pod, la version et le message de la configuration")
    void infoDitQuiARepondu() throws Exception {
        // GIVEN : la version et le message viennent de la configuration (le ConfigMap dans Kubernetes)

        // WHEN / THEN
        mvc.perform(get("/info"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.pod").isNotEmpty())
                .andExpect(jsonPath("$.version").value("2"))
                .andExpect(jsonPath("$.message").value("Salut"));
    }
}
