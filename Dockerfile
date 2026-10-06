# ── Build stage ────────────────────────────────────────────────���──────────────
FROM eclipse-temurin:21-jdk-jammy AS build
WORKDIR /workspace

# Install Maven
RUN apt-get update && apt-get install -y --no-install-recommends maven \
    && rm -rf /var/lib/apt/lists/*

# Copy pom first for layer-cache efficiency
COPY pom.xml .

# Download dependencies (cached layer)
RUN mvn dependency:go-offline -q || true

# Copy source and build fat JAR
COPY src/ src/
RUN mvn clean package -DskipTests -q

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM eclipse-temurin:21-jre-jammy

LABEL maintainer="platform-team@example.com"
LABEL description="Status Page API — Java 21 / Javalin"

WORKDIR /app

# Non-root user for least-privilege execution
RUN groupadd --system appgroup && useradd --system --gid appgroup appuser

COPY --from=build /workspace/target/statuspage-*.jar app.jar

RUN chown appuser:appgroup app.jar
USER appuser

# Port the Javalin server listens on
EXPOSE 8080

# AWS credentials are supplied via ECS task IAM role — no env vars needed
# CloudWatch logging is handled by the ECS awslogs log driver

ENTRYPOINT ["java", "-XX:+UseContainerSupport", "-XX:MaxRAMPercentage=75.0", \
            "-Djava.security.egd=file:/dev/./urandom", \
            "-jar", "app.jar"]