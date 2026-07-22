# Security policy

## Supported versions

PaymentReminder is early-stage software. Security fixes are applied to the current `main` branch;
older releases and forks are not maintained by the upstream project.

## Report a vulnerability

Do not open a public issue for a suspected vulnerability. Email
[arjun.builds.apps@gmail.com](mailto:arjun.builds.apps@gmail.com) with the subject
`[PaymentReminder security]`.

Include the affected revision, expected impact, and reproducible steps using synthetic data. Do not
send credentials, OAuth tokens, webhook secrets, real customer records, or other production data in
the first message. If sensitive supporting material is necessary, ask for a protected transfer
method first.

The maintainer will acknowledge the report, validate it, coordinate a fix, and discuss disclosure
timing with the reporter. If a live credential may already be exposed, revoke or rotate it with the
provider immediately rather than waiting for a code change.

Self-hosters are responsible for their deployment, access controls, provider credentials, backups,
monitoring, and incident response. Fork operators should replace this contact with their own
monitored security address before inviting users.
