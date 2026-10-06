package com.example.statuspage;

import io.javalin.Javalin;
import io.restassured.RestAssured;
import io.restassured.http.ContentType;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestInstance;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.*;

/**
 * Integration tests that start the Javalin application on a random port and
 * verify every endpoint's HTTP status code and JSON contract.
 *
 * <p>These tests satisfy acceptance criteria t7, t8, and t9.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class StatusPageIntegrationTest {

    private Javalin app;

    @BeforeAll
    void startServer() {
        app = Main.buildApp();
        app.start(0); // random available port
        RestAssured.port = app.port();
        RestAssured.basePath = "";
    }

    @AfterAll
    void stopServer() {
        if (app != null) {
            app.stop();
        }
    }

    // ── GET /health ───────────────────────────────────────────────────────────

    @Test
    void health_returns200WithStatusOk() {
        given()
            .when().get("/health")
            .then()
                .statusCode(200)
                .contentType(ContentType.JSON)
                .body("status", equalTo("ok"));
    }

    // ── GET /status ───────────────────────────────────────────────────────────

    @Test
    void status_returns200WithOperationalAndTimestamp() {
        given()
            .when().get("/status")
            .then()
                .statusCode(200)
                .contentType(ContentType.JSON)
                .body("status",    equalTo("operational"))
                .body("timestamp", notNullValue());
    }

    // ── POST /incident ────────────────────────────────────────────────────────

    @Test
    void createIncident_returns201WithAllFields() {
        given()
            .contentType(ContentType.JSON)
            .body("{\"title\":\"DB latency spike\",\"status\":\"investigating\"}")
        .when()
            .post("/incident")
        .then()
            .statusCode(201)
            .contentType(ContentType.JSON)
            .body("id",        notNullValue())
            .body("title",     equalTo("DB latency spike"))
            .body("status",    equalTo("investigating"))
            .body("createdAt", notNullValue());
    }

    @Test
    void createIncident_missingTitle_returns400() {
        given()
            .contentType(ContentType.JSON)
            .body("{\"status\":\"investigating\"}")
        .when()
            .post("/incident")
        .then()
            .statusCode(400)
            .body("error", notNullValue());
    }

    // ── GET /incident ─────────────────────────────────────────────────────────

    @Test
    void listIncidents_returns200WithArray() {
        given()
            .when().get("/incident")
            .then()
                .statusCode(200)
                .contentType(ContentType.JSON)
                .body("$", instanceOf(java.util.List.class));
    }

    // ── GET /incident/{id} ────────────────────────────────────────────────────

    @Test
    void getIncident_unknownId_returns404() {
        given()
            .when().get("/incident/does-not-exist")
            .then()
                .statusCode(404)
                .body("error", notNullValue());
    }

    @Test
    void getIncident_knownId_returns200() {
        // Create first, then retrieve
        String id =
            given()
                .contentType(ContentType.JSON)
                .body("{\"title\":\"Network blip\"}")
            .when()
                .post("/incident")
            .then()
                .statusCode(201)
                .extract().path("id");

        given()
            .when().get("/incident/" + id)
            .then()
                .statusCode(200)
                .body("id",    equalTo(id))
                .body("title", equalTo("Network blip"));
    }
}