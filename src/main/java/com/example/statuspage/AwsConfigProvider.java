package com.example.statuspage;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient;
import software.amazon.awssdk.services.secretsmanager.model.GetSecretValueRequest;
import software.amazon.awssdk.services.secretsmanager.model.GetSecretValueResponse;
import software.amazon.awssdk.services.secretsmanager.model.SecretsManagerException;
import software.amazon.awssdk.services.ssm.SsmClient;
import software.amazon.awssdk.services.ssm.model.GetParameterRequest;
import software.amazon.awssdk.services.ssm.model.GetParameterResponse;
import software.amazon.awssdk.services.ssm.model.SsmException;

/**
 * Loads runtime configuration from AWS Secrets Manager and SSM Parameter Store.
 *
 * <p>Authentication uses the SDK {@link DefaultCredentialsProvider} chain, which
 * resolves credentials in this order (no hard-coded keys):
 * <ol>
 *   <li>Environment variables (CI only — never in production images)</li>
 *   <li>ECS task IAM role (production)</li>
 *   <li>EC2 instance profile</li>
 *   <li>~/.aws/credentials (local development)</li>
 * </ol>
 *
 * <p>Set the environment variable {@code AWS_REGION} (or {@code AWS_DEFAULT_REGION})
 * to control the target region; falls back to {@code us-east-1}.
 */
public final class AwsConfigProvider {

    private static final Logger log = LoggerFactory.getLogger(AwsConfigProvider.class);

    /** SSM parameter name for the application environment label (e.g. "production"). */
    private static final String SSM_ENV_PARAM = "/statuspage/config/environment";

    /** Secrets Manager secret name for DB credentials (example — extend as needed). */
    private static final String SECRET_DB_CREDS = "statuspage/db/credentials";

    private AwsConfigProvider() {}

    /**
     * Initialises AWS-sourced configuration at application startup.
     *
     * <p>Failures are logged as warnings so the application can still start in
     * local/offline environments where AWS is not reachable.
     */
    public static void init() {
        Region region = resolveRegion();
        log.info("Initialising AWS config provider in region {}", region);

        loadSsmParameters(region);
        loadSecrets(region);
    }

    // ── SSM Parameter Store ───────────────────────────────────────────────────

    private static void loadSsmParameters(Region region) {
        try (SsmClient ssm = SsmClient.builder()
                .region(region)
                .credentialsProvider(DefaultCredentialsProvider.create())
                .httpClient(UrlConnectionHttpClient.create())
                .build()) {

            GetParameterResponse resp = ssm.getParameter(
                    GetParameterRequest.builder()
                            .name(SSM_ENV_PARAM)
                            .withDecryption(true)
                            .build());

            String env = resp.parameter().value();
            log.info("Loaded SSM parameter {}={}", SSM_ENV_PARAM, env);
            System.setProperty("app.environment", env);

        } catch (SsmException e) {
            log.warn("Could not load SSM parameter '{}': {} — using defaults",
                    SSM_ENV_PARAM, e.getMessage());
        } catch (Exception e) {
            log.warn("SSM unavailable ({}): {} — using defaults",
                    e.getClass().getSimpleName(), e.getMessage());
        }
    }

    // ── Secrets Manager ───────────────────────────────────────────────────────

    private static void loadSecrets(Region region) {
        try (SecretsManagerClient sm = SecretsManagerClient.builder()
                .region(region)
                .credentialsProvider(DefaultCredentialsProvider.create())
                .httpClient(UrlConnectionHttpClient.create())
                .build()) {

            GetSecretValueResponse resp = sm.getSecretValue(
                    GetSecretValueRequest.builder()
                            .secretId(SECRET_DB_CREDS)
                            .build());

            // Secret value is available via resp.secretString() or resp.secretBinary().
            // Parse and apply as needed — do NOT log the secret value.
            log.info("Loaded secret '{}' from Secrets Manager", SECRET_DB_CREDS);

        } catch (SecretsManagerException e) {
            log.warn("Could not load secret '{}': {} — using defaults",
                    SECRET_DB_CREDS, e.getMessage());
        } catch (Exception e) {
            log.warn("Secrets Manager unavailable ({}): {} — using defaults",
                    e.getClass().getSimpleName(), e.getMessage());
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static Region resolveRegion() {
        String regionStr = System.getenv("AWS_REGION");
        if (regionStr == null || regionStr.isBlank()) {
            regionStr = System.getenv("AWS_DEFAULT_REGION");
        }
        if (regionStr == null || regionStr.isBlank()) {
            regionStr = "us-east-1";
        }
        return Region.of(regionStr);
    }
}