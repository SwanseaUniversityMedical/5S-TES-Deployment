# 5S-TES Environment
Deployment Samples for [Five Safes TES](https://github.com/SwanseaUniversityMedical/5s-Tes).
User and Developer Guides can be found in the [documentation](https://docs.federated-analytics.ac.uk/).


## 📁 Project Structure

```bash
.
├── DemoStack/       # Demonstration instance of the stack (for dev and demonstration purposes)
├── DeploymentStack/ # Deployment files for Submission and TRE layers

├── ServiceStack/.   # Deployment files for all Services used by Submission and TRE
├── Diagram/         # Architecture or system diagrams
├── ansible/         # Ansible script to install funnel
└── README.md        # README.md
├── LICENCE.md       # LICENCE

```
## DemoStack
A Simple Demonstrator instance of the complete stack, intended to be run locally, not intended to be a production deployment.
```bash
.
├── config/
│   ├── funnel-config.yml   # Funnel configuration file
│   ├── funnel-work-dir     # Working directory for funnel
│   ├── init.sql            # SQL script for DB initialisation
│   ├── ldap-init           # LDAP initialisation files
│   └── realm-config        # Keycloak realm config for Submission, TRE and Egress
├── docker-compose.yml      # Demonstrator docker compose
├── .env                    # Environment variables
└── scripts
    ├── funnel.sh           # Script to automate funnel setup
    ├── starter.sh          # Script to automate demo stack setup
    └── submission-ready.sh # Script to automate submission setup
```

### To add New Services to the DemoStack
1. Create a new docker compose file for the service in `ServiceStack/compose-manifests/`.
2. Add the new compose file to the `include` section of `DemoStack/docker-compose.yml`.
3. Add any necessary configuration files to `DemoStack/config/` and reference them in the compose file.
    - For pointing the service to the config files, use `CONFIG_PATH` environment variable in the compose file.

**The docker compose includes:**

Application Services:
- Submission UI & Submission API
- TRE Agent UI & TRE Agent API
- Egress UI & Egress API
- TRE Camunda (Credential Worker)

Shared Services:
- Keycloak: includes realms defined in realm-config/
- PostgreSQL | Adminer | RabbitMQ | Seq

Authentication & Security:
- OpenLDAP | phpLDAPadmin | LDAP Init | HashiCorp Vault

Storage Services:
- MinIO: Submission & TRE Agent
- Elasticsearch

Orchestration Services:
- Camunda (Zeebe + Operate + Tasklist)
- Camunda Connectors

## DeploymentStack/Submission

A deployable instance of the Submission Layer.

```bash
DeploymentStack/Submission/
.
├── config/
│   ├── init.sql                # SQL script for DB initialisation
│   └── realm-config/
│       └── sub-layer.json      # Keycloak Submission realm configuration
├── .env                        # Environment variables for Submission deployment
├── docker-compose.yml
```
The docker compose includes:
- Submission UI & Submission API
- Keycloak (Submission realm defined in `config/realm-config/sub-layer.json`)
- PostgreSQL | RabbitMQ | Seq | Nginx 
- Submission RustFS

## TRE
```bash
DeploymentStack/TRE/
.
├── config/
│   ├── init.sql                 # SQL script for DB initialisation
│   ├── ldap-init/
│   │   └── init.ldif            # OpenLDAP initialisation file
│   └── realm-config/
│       ├── tre-layer.json       # Keycloak TRE realm configuration
│       └── egress-layer.json    # Keycloak Egress realm configuration
├── .env                         # Environment variables for TRE deployment
├── docker-compose.yml
```

The docker compose includes:
- TRE Agent UI & TRE Agent API
- Egress UI & Egress API
- Keycloak (TRE & Egress realms defined in `config/realm-config/`)
- Credential Services: Camunda | Connectors | Vault | OpenLDAP | LDAP Init | phpLDAPadmin | Elastic Search
- PostgreSQL | RabbitMQ | Seq | Nginx
- TRE Agent RustFS

## Getting a Vault Token (Submission / TRE DeploymentStacks)

Both `DeploymentStack/Submission` and `DeploymentStack/TRE` run HashiCorp Vault in **config file mode** (`VaultStartupCommand="vault server -config=/vault/config/config.json"`), not dev mode. This means Vault starts **uninitialized and sealed** — it will not generate a root token automatically, and its healthcheck (and anything depending on it, e.g. `submissionAPI`) will not pass until it is initialized and unsealed manually.

1. Start the stack as normal (`docker compose up -d`). The `vault` container will come up but report `health: starting` / unhealthy — this is expected at this point.
2. Initialize Vault (only needed once per Vault data volume):
   ```bash
   docker exec vault vault operator init -key-shares=1 -key-threshold=1
   ```
   This prints a single **unseal key** and a **root token**. Save both somewhere safe (e.g. a password manager) — they are not shown again, and losing the unseal key permanently locks out any secrets stored in Vault's data volume.
   - `-key-shares=1 -key-threshold=1` is used here for simplicity on a single local instance. For a real production deployment, use Vault's defaults (5 shares / 3 threshold) or your organisation's key-management process instead.
3. Unseal Vault with the key from step 2:
   ```bash
   docker exec vault vault operator unseal <unseal_key>
   ```
4. Put the root token from step 2 into the stack's `.env` file:
   ```
   VaultRootToken=<root_token>
   ```
5. Recreate the dependent services so they pick up the token:
   ```bash
   docker compose up -d
   ```

**Note:** Because this is file storage (not dev mode), Vault re-seals every time the container restarts. After any restart, repeat step 3 (`vault operator unseal <unseal_key>`) before dependent services will become healthy — no need to repeat step 2 or generate a new token.
