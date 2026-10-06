package com.example.statuspage;

import io.javalin.Javalin;
import io.javalin.http.Context;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Status Page REST API — Java 21 / Javalin 6.
 *
 * <p>All endpoints replicate the behaviour of the original com.sun.net.httpserver
 * implementation without referencing any internal JDK API.
 *
 * <p>Structured logging to stdout makes log lines compatible with the AWS ECS
 * {@code awslogs} log driver and CloudWatch Logs Insights.
 */
public class Main {

    private static final Logger log = LoggerFactory.getLogger(Main.class);
    private static final ObjectMapper mapper = new ObjectMapper();

    /** In-memory incident store (keyed by UUID string). */
    private static final Map<String, ObjectNode> incidents = new ConcurrentHashMap<>();

    // ── Entry point ───────────────────────────────────────────────────────────

    public static void main(String[] args) {
        int port = resolvePort();
        Javalin app = buildApp();
        app.start(port);
        log.info("event=startup port={} java={}", port, System.getProperty("java.version"));
    }

    // ── Application factory (also used by integration tests) ─────────────────

    /**
     * Builds and configures the Javalin application without starting it.
     * Tests call this method and then invoke {@code app.start(0)} to bind on a
     * random available port.
     */
    public static Javalin buildApp() {
        Javalin app = Javalin.create(config -> {
            config.bundledPlugins.enableCors(cors -> cors.addRule(it -> it.anyHost()));
        });

        // ── Routes ────────────────────────────────────────────────────────────
        app.get("/health",        Main::handleHealth);
        app.get("/status",        Main::handleStatus);
        app.get("/incident",      Main::handleListIncidents);
        app.post("/incident",     Main::handleCreateIncident);
        app.get("/incident/{id}", Main::handleGetIncident);

        return app;
    }

    // ── Handlers ───────────────────────��──────────────────────────────────────

    /** GET /health — liveness probe. */
    private static void handleHealth(Context ctx) {
        ObjectNode body = mapper.createObjectNode();
        body.put("status", "ok");
        ctx.status(200).json(body);
        log.info("event=health_check result=ok");
    }

    /** GET /status — overall system status. */
    private static void handleStatus(Context ctx) {
        ObjectNode body = mapper.createObjectNode();
        body.put("status", "operational");
        body.put("timestamp", Instant.now().toString());
        ctx.status(200).json(body);
        log.info("event=status_check status=operational");
    }

    /** GET /incident — list all incidents. */
    private static void handleListIncidents(Context ctx) {
        ctx.status(200).json(incidents.values());
        log.info("event=list_incidents count={}", incidents.size());
    }

    /** POST /incident — create a new incident. */
    private static void handleCreateIncident(Context ctx) {
        ObjectNode request;
        try {
            request = mapper.readValue(ctx.body(), ObjectNode.class);
        } catch (Exception e) {
            log.warn("event=create_incident result=bad_request reason=invalid_json");
            ctx.status(400).json(errorBody("Invalid JSON body"));
            return;
        }

        if (!request.hasNonNull("title") || request.get("title").asText().isBlank()) {
            log.warn("event=create_incident result=bad_request reason=missing_title");
            ctx.status(400).json(errorBody("Field 'title' is required"));
            return;
        }

        String id = UUID.randomUUID().toString();
        String title = request.get("title").asText();
        String status = request.has("status") ? request.get("status").asText() : "investigating";

        ObjectNode incident = mapper.createObjectNode();
        incident.put("id", id);
        incident.put("title", title);
        incident.put("status", status);
        incident.put("createdAt", Instant.now().toString());

        incidents.put(id, incident);

        log.info("event=create_incident id={} title={} status={}", id, title, status);
        ctx.status(201).json(incident);
    }

    /** GET /incident/{id} — retrieve a single incident. */
    private static void handleGetIncident(Context ctx) {
        String id = ctx.pathParam("id");
        ObjectNode incident = incidents.get(id);
        if (incident == null) {
            log.warn("event=get_incident id={} result=not_found", id);
            ctx.status(404).json(errorBody("Incident not found: " + id));
            return;
        }
        log.info("event=get_incident id={} result=found", id);
        ctx.status(200).json(incident);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static ObjectNode errorBody(String message) {
        ObjectNode node = mapper.createObjectNode();
        node.put("error", message);
        return node;
    }

    private static int resolvePort() {
        String env = System.getenv("PORT");
        if (env != null && !env.isBlank()) {
            try {
                return Integer.parseInt(env.trim());
            } catch (NumberFormatException ignored) {
                // fall through to default
            }
        }
        return 8080;
    }
}