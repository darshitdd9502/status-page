package com.example.statuspage;

import io.javalin.http.Context;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.Instant;
import java.util.Map;

/**
 * Handles GET /status — returns overall system status.
 */
public class StatusHandler {

    private static final Logger log = LoggerFactory.getLogger(StatusHandler.class);

    public void getStatus(Context ctx) {
        log.info("GET /status");
        ctx.status(200).json(Map.of(
                "status",    "operational",
                "timestamp", Instant.now().toString()
        ));
    }
}