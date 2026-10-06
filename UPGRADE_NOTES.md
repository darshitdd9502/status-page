# Upgrade Notes — statuspage-sample-code

## Summary of Changes

### 1. Java Runtime: 8 → 21 LTS

| File | Change |
|------|--------|
| `pom.xml` | `<maven.compiler.release>21</maven.compiler.release>` replaces all `1.8` / `8` source/target references |
| `Dockerfile` | Build stage: `eclipse-temurin:21-jdk-jammy`; runtime stage: `eclipse-temurin:21-jre-jammy` |
| `.github/workflows/ci.yml` | `java-version: '21'` in `actions/setup-java` |

### 2. HTTP Server: com.sun.net.httpserver → Javalin 6

The internal JDK `com.sun.net.httpserver` package has been completely removed.  
`Main.java` now uses **Javalin 6** (`io.javalin:javalin:6.3.0`), a lightweight,
production-supported HTTP framework that runs on Java 21 without any
`--add-opens` or `--illegal-access` flags.

Key design decisions:
- `Main.buildApp()` is a static factory that returns a configured `Javalin`
  instance without starting it, enabling integration tests to bind on a random
  port (`app.start(0)`).
- All five original endpoints are preserved with identical HTTP status codes and
  JSON response shapes:
  - `GET  /health`        → 200 `{"status":"ok"}`
  - `GET  /status`        → 200 `{"status":"operational","timestamp":"..."}`
  - `GET  /incident`      → 200 `[...]`
  - `POST /incident`      → 201 `{"id":...,"title":...,"status":...,"createdAt":...}` / 400 on validation error
  - `GET  /incident/{id}` → 200 or 404

### 3. Dependency: maven-shade-plugin (fat JAR)

`maven-shade-plugin 3.6.0` produces a single executable JAR
(`statuspage-1.0.0.jar`) with the `Main-Class` manifest entry set.  
The `ServicesResourceTransformer` merges `META-INF/services/` entries required
by Javalin's Jetty internals.

### 4. Logging — CloudWatch-compatible stdout

`logback.xml` configures a `ConsoleAppender` with a timestamped pattern:

```
2024-01-15T12:34:56.789+0000 INFO  c.e.s.Main - event=startup port=8080 java=21
```

When the ECS task uses the `awslogs` log driver, these lines appear in the
designated CloudWatch Log Group within seconds of startup.

### 5. AWS SDK v2 — IAM Role Authentication

The AWS SDK v2 BOM (`software.amazon.awssdk:bom:2.26.12`) is imported.
Modules declared:
- `secretsmanager` — runtime secrets (no hardcoded credentials)
- `ssm` — SSM Parameter Store for configuration
- `cloudwatch` — custom metrics
- `url-connection-client` — lightweight synchronous HTTP client (avoids Netty)

**No `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` environment variables are
set anywhere.** The SDK's `DefaultCredentialsProvider` chain picks up the ECS
task IAM role automatically.

### 6. Security — No Hardcoded Secrets

`grep -rE '(password|secret|api_key|apikey|token)\s*=\s*["\x27][^"\x27]+["\x27]'`
returns zero matches across `src/`, `Dockerfile`, and `pom.xml`.

---

## Manual Follow-ups Required

### A. ECS Task Definition
- Set `taskRoleArn` to an IAM role with least-privilege policies:
  - `secretsmanager:GetSecretValue` on the application's secret ARNs
  - `ssm:GetParameter` / `ssm:GetParametersByPath` on the parameter paths
  - `cloudwatch:PutMetricData` on the target namespace
- Configure the `awslogs` log driver:
  ```json
  "logConfiguration": {
    "logDriver": "awslogs",
    "options": {
      "awslogs-group": "/ecs/statuspage",
      "awslogs-region": "us-east-1",
      "awslogs-stream-prefix": "ecs"
    }
  }
  ```

### B. Secrets Manager Integration
Any runtime secrets (e.g., database passwords) must be fetched at startup via:
```java
SecretsManagerClient client = SecretsManagerClient.builder()
    .httpClient(UrlConnectionHttpClient.create())
    .build();
String secret = client.getSecretValue(r -> r.secretId("my/secret")).secretString();
```
Never pass secrets as environment variables or embed them in source.

### C. CVE Scanning
Run `trivy image statuspage:ci` or `docker scout cves statuspage:ci` in CI.
The Trivy step in `.github/workflows/ci.yml` is already configured to fail the
build on HIGH/CRITICAL CVEs. Pin dependency versions and rebuild the image
regularly to pick up security patches.

### D. Persistent Incident Storage
The current implementation uses an in-memory `ConcurrentHashMap`. For
production, replace this with an AWS-native store:
- **Amazon DynamoDB** (recommended for serverless/ECS workloads)
- **Amazon RDS / Aurora** (if relational schema is needed)

### E. Systemd Alignment
The original Dockerfile comment noted that production deployment used systemd.
The containerised deployment is now the single authoritative artifact. Remove
the systemd unit file from production hosts and deploy exclusively via ECS /
Docker to ensure a consistent runtime.