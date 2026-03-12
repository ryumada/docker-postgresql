# Docker PostgreSQL DevOps Deployment

This repository provides a production-grade, highly optimized PostgreSQL deployment using Docker Compose. It emphasizes Infrastructure as Code (IaC), security via Docker secrets, and automated initialization scripts.

## Features

- **Automated Parameter Tuning:** Natively configures `postgresql.conf` based on your `.env` settings to fully utilize SSDs, parallel CPU query gathering, and optimized RAM buffers (pre-tuned for a 4GB-8GB VM).
- **Secure Secrets Management:** Removes hardcoded passwords from `docker-compose.yml`. Passwords are auto-generated as secure, humand-readable three-word passphrases injected directly into the container's `.txt` secret mounts.
- **Dynamic Database Ownership:** A host-executed CLI script allows for the instant creation of application-specific users and database ownership transfers via temporary Docker containers (eliminating the need for a local `psql` client on the host).

## Requirements

- Docker
- Docker Compose v2
- Git
- Bash

## Quick Start

### 1. Configure the Environment

Copy the example environment file and adjust the parameters to fit your needs (specifically the `EXTERNAL_NETWORK_NAME` if you are using an existing Docker network):

```bash
cp .env.example .env
```

*Review `.env.example` for detailed explanations of each PostgreSQL tuning parameter.*

### 2. Run the Initial Setup

Execute the `setup.sh` script to automatically:
1.  Read your `.env` file.
2.  Generate a highly tuned `config/postgresql.conf`.
3.  Auto-generate a secure 3-word passphrase for the primary `MAINTENANCE_USER` and save the credentials into the `./secrets` directory.

```bash
./setup.sh
```

### 3. Deploy PostgreSQL

Once the setup is complete and the `secrets/` directory is populated:

```bash
docker compose up -d
```

*This will boot Postgres, reading exactly what it needs from the generated configuration and securely mapped secret files.*

---

## Managing Secondary Application Users

It is a best practice not to give out the primary `MAINTENANCE_USER` (superuser) credentials to individual applications or developers.

When you need to create a new database user for a distinct application (e.g., `my_app_user`):

```bash
# General Usage
./scripts/create_postgres_user.sh <username> [password]

# Auto-generate a secure password for a new developer or application
./scripts/create_postgres_user.sh my_erp_user
```

**How it works:** This script will immediately generate a new set of password secrets into the `secrets/` directory. If the PostgreSQL container is currently running, it will directly execute the necessary `CREATE USER` and `CREATE DATABASE` SQL commands against the database via a temporary disposable `docker run psql` container.
