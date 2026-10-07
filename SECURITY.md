# Security policy

## Reporting a vulnerability

**Do not open a public issue.** Use GitHub *Security Advisories* (the *Security* tab, then *Report a vulnerability*) to report privately.

Include the image version (tag or digest), the steps to reproduce and the impact. An acknowledgement is sent as soon as possible; there is no guaranteed response time.

## Supported versions

Only the latest published version is fixed.

## Threat model

- The backup server only holds the age **public key**: a leak of its environment cannot decrypt existing backups.
- Secrets (`PGPASSWORD`, S3 keys) go through the container environment, never through the command line.
- The container runs unprivileged (user 10001) and works with a read-only filesystem.

## Out of scope

- Losing the age private key makes backups unrecoverable: this is expected behavior, not a vulnerability.
- Behavior against a compromised or malicious S3 provider: the tool does not verify object integrity after upload beyond what S3 guarantees.
- Vulnerabilities in the bundled Alpine packages, `age`, `rclone` and `pg_dump`: report them upstream, then here if an image update is needed.
