# Database Secrets Directory

This directory is dynamically managed and heavily restricted by the deployment automation scripts. **Do not commit text files from this directory to version control.**

## Purpose

The files within this directory (`*_user.txt` and `*_password.txt`) act as secure material mounts for Docker.

When the PostgreSQL container is initialized (via `docker compose up -d`), it natively reads from these explicit files to instantiate the initial `MAINTENANCE_USER`, rather than taking raw passwords defined directly inside `docker-compose.yml` environment variables.

### Management

- These files are auto-generated with strict `600` permissions (read/write only by the repository owner) via the `./setup.sh` and `./scripts/create_postgres_user.sh` automation scripts.
- The `setup.sh` script specifically utilizes a custom passphrase generator to create secure, human-readable three-word passwords formatted as `<word>-<word>-<word>`.

## Example Contents

After running the setup, you should expect to see:

- `maintenance_user.txt` (Contains the superuser name generated from the `.env` file)
- `maintenance_password.txt` (Contains the auto-generated passphrase)
