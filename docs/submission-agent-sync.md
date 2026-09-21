should be # How Submission ↔ TRE Agent Sync Works

This document describes the background sync between the Submission layer and the TRE
Agent (`tre-api`), and how the TRE grants ephemeral credentials to approved users via
Camunda/Zeebe. It's based on tracing the actual running system (logs, Zeebe event
records, database contents), not just reading source, so it reflects what the DemoStack
deployment does today.

## Components involved

| Component | Container | Role |
|---|---|---|
| Submission API | `submissionAPI` | Owns submissions, projects, membership decisions. Exposes sync endpoints for the TRE to poll. |
| TRE Agent API | `treapi` (image `agent-api`) | Hosts the Hangfire background jobs. Polls Submission API, starts Camunda processes, tracks credential issuance. |
| TRE Camunda Worker | `TRE-Camunda` (image `credentials-camunda`) | Deploys the BPMN/DMN process models to Zeebe and runs the Zeebe job workers that actually create credentials. |
| Zeebe | `zeebe` | Camunda 8 workflow engine (self-managed, community/no Operate). Executes the `Start_Credentials` process. |
| Postgres | `postgres` | Hosts `DARE-Tre` (TRE app data), `TRE_Credentials` (ephemeral credential tracking), `DARE-Control` (submission layer data), `hangfire` (job storage). |
| Vault | `vault` | Stores issued credentials/secrets for retrieval by the researcher's environment. |

There is **no** Camunda Connectors runtime in this deployment — it was intentionally
removed (commit `4d2419c Remove unecessary camunda connectors`). Process instances are
started directly via the Zeebe gRPC client from `treapi`, not via inbound HTTP webhooks.

## Scheduling: Hangfire in `treapi`

Hangfire runs inside the `treapi` container (not a separate service). Configuration
comes from `ServiceStack/compose-manifests/applications/tre-layer.yml` and `.env`:

```
Hangfire__Username              = ${HangfireUser}              # admin
Hangfire__Password              = ${HangfirePassword}          # password
JobSettings__scanSchedule       = ${scanSchedule}               # minutes, default 1
JobSettings__syncSchedule       = ${syncSchedule}                # minutes, default 2 (10 in non-demo)
```

Two recurring job families run on those schedules:

- **Scan job** (every `scanSchedule` minutes) — looks for submissions waiting on TRE
  access and starts the credential-issuing Camunda process for each one.
- **Sync job** (every `syncSchedule` minutes) — pushes project/membership decisions
  between the two layers so both sides agree on who currently has access.

The Hangfire dashboard is served by `treapi` itself (`http://localhost:8072`, the
container's published port), protected by `Hangfire__Username`/`Hangfire__Password`.

## Step-by-step flow

1. **Scan.** `treapi` calls `GET http://submissionapi:8080/api/Submission/GetWaitingSubmissionsForTre`
   to get submissions that have been approved on the Submission side but don't have TRE
   credentials yet.

2. **Decision sync.** For each cycle, `treapi` also calls:
   - `POST http://submissionapi:8080/api/Project/SyncTreProjectDecisions`
   - `POST http://submissionapi:8080/api/Project/SyncTreMembershipDecisions`

   These push the TRE's view of project/membership approvals back to the Submission
   layer, keeping `MembershipDecisions` and `Projects.Decision` in sync on both sides.

3. **Start the credential process.** For a waiting submission, `treapi` calls Zeebe's
   `CreateProcessInstance` directly (gRPC, via `ZeebeBootstrap__Client__GatewayAddress=zeebe:26500`),
   starting the `Start_Credentials` process (defined in `Credentials.bpmn`) with
   variables already flattened out, e.g.:

   ```json
   {
     "submissionId": "2",
     "project": "Testing",
     "user": "1",
     "InputCollections": [ { "project": "Testing", "user": "1", "submissionId": "2" } ]
   }
   ```

4. **DMN decision.** The process's first real step is a business rule task ("Credentials
   DMN") that runs once per entry in `InputCollections` (multi-instance) and evaluates
   the `CredentialsDMN` decision table to work out what access the user should get.

5. **Provisioning.** Downstream service tasks are picked up by Zeebe job workers running
   in `TRE-Camunda`. On startup it registers 9 workers:
   `create-postgres-user`, `create-trino-user`, `create-tre-credentials`,
   `delete-postgres-user`, `delete-trino-user`, `delete-tre-credentials`,
   `store-in-vault`, `storeParentKey`, `set-success-status`.
   These create the actual database users/credentials, write the secret into Vault, and
   record the result.

6. **Tracking.** Each credential granted is written as a row in
   `TRE_Credentials.EphemeralCredentials` (`SubmissionId`, `CredentialType` —
   `postgres`/`trino`/`tre` — `IsProcessed`, `SuccessStatus`, `VaultPath`,
   `ProcessInstanceKey`, `ExpiredAt`). `treapi` polls this table for the submission it
   just triggered and retries within the same Hangfire run for a short window; if
   nothing shows up yet it logs `"Still no credentials after retry window. Skipping
   until next Hangfire cycle."` and picks it up again next cycle.

7. **Revocation/expiry.** Two other processes, `Credentials_Revoke.bpmn` and
   `Credentials_Expire_Subprocess.bpmn`, handle removing access — same worker set,
   `delete-*` job types.

## Process models are deployed from a shared volume, not baked in at runtime

`TRE-Camunda` and `treapi` both mount the same named volume at `/app/ProcessModels`
(`tre_process_models`, declared in `DemoStack/docker-compose.yml`). On startup
`TRE-Camunda` scans that directory and deploys every `.bpmn`/`.dmn` file it finds to
Zeebe (`DmnPath__Path=/app/ProcessModels` on both services).

Important operational detail: this is a **named Docker volume**. Docker only
copies a service's image content into it the first time the volume is created. If you
change the `credentials-camunda` image tag later, the already-populated volume keeps
serving the *old* files — the new image's `/app/ProcessModels` contents are not picked
up automatically. Redeploying a fixed process model after an image bump means either
recreating the volume from empty, or explicitly copying the new files in and restarting
`TRE-Camunda`.

## Known issue history (as of 2026-07-07)

The Camunda downgrade work removed the Connectors runtime (`4d2419c`) and moved process
instance creation to a direct Zeebe call in the application layer. That change shipped
in `agent-api:pr-129-ea56fb7`, but `Credentials.bpmn`'s `StartCredentials` start event
was still configured as a **Camunda Connectors webhook** start event — it expected a
`body` variable that only the (now-removed) connector runtime would ever populate.
Every process instance failed immediately with:

```
IO_MAPPING_ERROR: failed to evaluate expression
'{project:body.records.project,user:body.records.user,...}'
no variable found for name 'body'
```

`credentials-camunda:pr-129-ea56fb7` contains the matching fix (a plain start event,
no webhook mapping) but `tre-layer.yml` had `TRE-Camunda` pinned to `${DEPLOYMENT_VERSION}`
(`2.1.0`) instead. `TRE-Camunda` is now pinned to `credentials-camunda:pr-129-ea56fb7`
to match `tre-api`, and the fixed process models were copied into the live
`tre_process_models` volume so credential issuance completes end-to-end.

**Outstanding, separate issue:** `Credentials_Revoke.bpmn` throws its own
`IO_MAPPING_ERROR` (`context contains no entry with key 'tag'`) on its DMN task — likely
the same "leftover webhook-era mapping" pattern, just in the revoke flow instead of the
start flow. Not yet fixed.

## Where to look when sync "isn't working"

- **Nothing happening at all** → check `treapi` logs for the scan cycle
  (`GetWaitingSubmissionsForTre`, `SyncTreProjectDecisions`) — confirms Hangfire is
  actually firing and reaching the Submission API.
- **Process starts but nothing completes** → check Zeebe incidents in Elasticsearch:
  `GET http://localhost:9200/zeebe-record_incident_*/_search?sort=timestamp:desc` — an
  `IO_MAPPING_ERROR` here means a process/DMN input mapping doesn't match the variables
  actually being passed in.
  There's currently no Operate/Kibana UI wired up for this (both were removed), so the
  Elasticsearch zeebe-record indices are the only way to inspect process state.
- **Credentials never appear** → connect to the `TRE_Credentials` database (it's a
  separate database on the same Postgres instance, not a schema) and query
  `SELECT * FROM "EphemeralCredentials" WHERE "SubmissionId" = <id>;`
  to see if/why issuance failed.
