package com.example.statuspage;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.javalin.http.Context;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Handles CRUD operations for incidents.
 *
 * <p>In-memory store — replace with RDS/Aurora persistence for production.
 */
public class IncidentHandler {

    private static final Logger log = LoggerFactory.getLogger(IncidentHandler.class);
    private static final ObjectMapper MAPPER = new ObjectMapper();

    /** Thread-safe in-memory store keyed by incident ID. */
    private final ConcurrentHashMap<String, Map<String, Object>> store = new ConcurrentHashMap<>();

    // ── POST /incident ────────────────────────────────────────────────────────

    public void createIncident(Context ctx) {
        try {
            JsonNode body = MAPPER.readTree(ctx.body());

            if (!body.hasNonNull("title") || body.get("title").asText().isBlank()) {
                ctx.status(400).json(Map.of("error", "Field 'title' is required"));
                return;
            }

            String id        = UUID.randomUUID().toString();
            String title     = body.get("title").asText();
            String status    = body.hasNonNull("status") ? body.get("status").asText() : "investigating";
            String createdAt = Instant.now().toString();

            Map<String, Object> incident = new ConcurrentHashMap<>();
            incident.put("id",        id);
            incident.put("title",     title);
            incident.put("status",    status);
            incident.put("createdAt", createdAt);

            store.put(id, incident);
            log.info("Created incident id={} title={}", id, title);
            ctx.status(201).json(incident);

        } catch (Exception e) {
            log.error("Error creating incident", e);
            ctx.status(400).json(Map.of("error", "Invalid request body"));
        }
    }

    // ── GET /incident ─────────────────────────────────────────────────────────

    public void listIncidents(Context ctx) {
        List<Map<String, Object>> incidents = new ArrayList<>(store.values());
        log.info("GET /incident — returning {} incidents", incidents.size());
        ctx.status(200).json(incidents);
    }

    // ── GET /incident/{id} ────────────────────────────────────────────────────

    public void getIncident(Context ctx) {
        String id = ctx.pathParam("id");
        Map<String, Object> incident = store.get(id);
        if (incident == null) {
            ctx.status(404).json(Map.of("error", "Incident not found: " + id));
            return;
        }
        ctx.status(200).json(incident);
    }

    // ── PUT /incident/{id} ────────────────────────────────────────────────────

    public void updateIncident(Context ctx) {
        String id = ctx.pathParam("id");
        Map<String, Object> incident = store.get(id);
        if (incident == null) {
            ctx.status(404).json(Map.of("error", "Incident not found: " + id));
            return;
        }

        try {
            JsonNode body = MAPPER.readTree(ctx.body());

            if (body.hasNonNull("title")) {
                incident.put("title", body.get("title").asText());
            }
            if (body.hasNonNull("status")) {
                incident.put("status", body.get("status").asText());
            }
            incident.put("updatedAt", Instant.now().toString());

            store.put(id, incident);
            log.info("Updated incident id={}", id);
            ctx.status(200).json(incident);

        } catch (Exception e) {
            log.error("Error updating incident id={}", id, e);
            ctx.status(400).json(Map.of("error", "Invalid request body"));
        }
    }

    // ── DELETE /incident/{id} ─────────────────────────────────────────────────

    public void deleteIncident(Context ctx) {
        String id = ctx.pathParam("id");
        if (!store.containsKey(id)) {
            ctx.status(404).json(Map.of("error", "Incident not found: " + id));
            return;
        }
        store.remove(id);
        log.info("Deleted incident id={}", id);
        ctx.status(204);
    }
}