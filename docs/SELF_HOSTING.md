# Self-hosting and operations

PaymentReminder can be run from an image built with the included production Dockerfile or deployed
with Kamal. The image contains the Rails application; it does not contain MySQL, provider
applications, SMTP, or a second worker process.

This is an operator guide, not a one-command appliance installer. Validate the deployment against
your own domain, infrastructure, providers, privacy terms, and recovery requirements before
inviting users.

## Production architecture

| Component | Command or service | Responsibility |
| --- | --- | --- |
| Web | `./bin/thrust ./bin/rails server` | HTTP, account UI, OAuth callbacks, webhooks, health endpoint |
| Jobs | `bin/jobs` | Solid Queue work and production recurring schedules |
| Database | MySQL 8 | Primary data plus Solid Cache, Queue, and Cable databases |
| System mail | SMTP, configured for SES by default | Sign-in codes and user notifications |
| Gmail | Per-account Gmail OAuth connection | Customer reminders and screened mailbox ingestion |
| TLS / proxy | Kamal Proxy or your reverse proxy | Public HTTPS termination and forwarding |

Both web and jobs use the same application image, `RAILS_MASTER_KEY`, provider credentials, and
database server. A healthy web container does not imply a healthy worker.

After the first production boot, visit `<HOST>/signup/new`, create the first account owner, and
verify system-email delivery when using email-code authentication. To make that identity the
installation operator, add its exact email address to the platform-admin allowlist, restart the
app, sign in, and open `<HOST>/madmin`. See [Platform administration](PLATFORM_ADMIN.md).

## Fork checklist

Before deploying a fork:

1. Create fork-owned Rails credentials and a master key as described in
   [Configuration](CONFIGURATION.md).
2. Choose the application name, public HTTPS origin, support address, and system-email sender.
3. Replace the official marketing redirect in `app/controllers/landing_controller.rb`.
4. Review and rewrite the privacy policy, terms, and `SECURITY.md` contact for the operator,
   jurisdiction, providers, data use, retention, deletion, and contact process of the fork.
5. Decide whether public self-service signup is intended. `/signup/new` and `/signup/xero` remain
   open to anyone who can reach the service; there is no invite-only or registration-disable
   setting, so restrict or change that behavior before launch when operating a closed instance.
6. Replace every installation-specific value in `config/deploy.yml`: service/image names, web and
   job hosts, proxy host and TLS mode, registry, database host, mail identity, and volume name.
7. Decide whether to keep the historical `paid_jar` database role/names in `config/database.yml` or
   migrate them deliberately.
8. Create provider applications owned by the fork and register callbacks/webhooks for its `HOST`.
9. Replace the Stripe App ID, redirect URI, origin constant, and content-security-policy origin in
   `stripe-app/stripe-app.json` before uploading it from the fork's Stripe account. Review the
   private-App webhook limitation in [Integrations](INTEGRATIONS.md) before choosing distribution.
10. Configure database backups, master-key recovery, error monitoring, worker monitoring, and a
   tested restore path.
11. Review the [AGPL-3.0 license](../LICENSE) before offering a modified network service.

This search finds the main upstream-specific values that need deliberate review:

```bash
rg -n 'paymentreminderemails\.com|paid_jar|weightlessapps|arjunbuilds' \
  app config Dockerfile stripe-app
```

Do not replace fixture names mechanically. Review each production and public-facing match in
context.

## Database

The checked-in production configuration expects one MySQL server, the `paid_jar` application user,
and these databases:

- `paid_jar_production`
- `paid_jar_production_cache`
- `paid_jar_production_queue`
- `paid_jar_production_cable`

It reads the host from `DB_HOST` and the application user's password from
`MYSQL_ROOT_PASSWORD`. The variable name is historical: it is passed as the `paid_jar` role's
password, so it should not imply that the application connects as MySQL root.

Provision the role and databases before boot, or grant the role permission to create them during
the first `db:prepare`. Limit network access to the application hosts and use encrypted transport
where the database crosses a network boundary.

One explicit MySQL 8 provisioning shape is:

```sql
CREATE DATABASE paid_jar_production CHARACTER SET utf8mb4;
CREATE DATABASE paid_jar_production_cache CHARACTER SET utf8mb4;
CREATE DATABASE paid_jar_production_queue CHARACTER SET utf8mb4;
CREATE DATABASE paid_jar_production_cable CHARACTER SET utf8mb4;
CREATE USER 'paid_jar'@'%' IDENTIFIED BY '<strong-random-password>';
GRANT ALL PRIVILEGES ON paid_jar_production.* TO 'paid_jar'@'%';
GRANT ALL PRIVILEGES ON paid_jar_production_cache.* TO 'paid_jar'@'%';
GRANT ALL PRIVILEGES ON paid_jar_production_queue.* TO 'paid_jar'@'%';
GRANT ALL PRIVILEGES ON paid_jar_production_cable.* TO 'paid_jar'@'%';
```

Restrict `%` to the application hosts or private network when the platform provides a stable host
pattern. Put the same password in the deployment secret exposed as `MYSQL_ROOT_PASSWORD`; do not
store it in this file or in shell history.

The production web-image entrypoint runs `bin/rails db:prepare` before the Rails server. A worker
container does not run that preparation step, so start or migrate the web release before starting
workers on a new version.

## Deploy with Kamal

Kamal is the repository's primary deployment path, but `config/deploy.yml` is the upstream
maintainer's live topology—not a safe template to execute unchanged.

At minimum, update:

- `service` and `image`;
- every web/job host;
- `proxy.host` and `proxy.ssl`;
- registry server, username, and secret source;
- `DB_HOST`;
- `HOST`, mailer host/domain/from address, and SES endpoint if needed;
- persistent volume name and builder architecture.

Review `.kamal/secrets`. It reads the registry password from the environment and the Rails master
key plus selected values from local encrypted credentials. Do not put raw secrets in
`config/deploy.yml` or commit them to `.kamal/secrets`.

Once the configuration points only to infrastructure controlled by the fork, the normal Kamal
flow is:

```bash
bin/kamal setup
bin/kamal deploy
bin/kamal app details
bin/kamal logs -r web
bin/kamal logs -r job
```

Run these commands only after reviewing the resolved hosts, registry, proxy, and secrets. The
checked-in aliases also provide `bin/kamal console`, `bin/kamal shell`, and `bin/kamal dbc`.

Production forces SSL and assumes a TLS-terminating proxy. Ensure the proxy forwards the original
HTTPS scheme correctly. If Kamal Proxy obtains certificates, point DNS at the web host before
enabling its SSL option; otherwise terminate TLS in the chosen load balancer or reverse proxy.

## Run the Docker image directly

The Dockerfile is production-only. Build one image and run it as two services against an external
MySQL server:

Create a protected environment file outside the repository:

```text
RAILS_MASTER_KEY=your-fork-master-key
DB_HOST=mysql.internal
MYSQL_ROOT_PASSWORD=your-application-database-password
HOST=https://receivables.example.com
MAILER_HOST=receivables.example.com
MAILER_PROTOCOL=https
MAILER_DOMAIN=example.com
MAILER_FROM_ADDRESS=PaymentReminder <support@example.com>
```

```bash
docker build -t payment-reminder:local .

docker run -d \
  --name payment-reminder-web \
  --env-file /secure/path/payment-reminder.env \
  -p 127.0.0.1:3000:80 \
  -v payment-reminder-storage:/rails/storage \
  payment-reminder:local

docker run -d \
  --name payment-reminder-jobs \
  --env-file /secure/path/payment-reminder.env \
  payment-reminder:local \
  bin/jobs
```

The protected environment file must supply at least `RAILS_MASTER_KEY`, `DB_HOST`,
`MYSQL_ROOT_PASSWORD`, and `HOST`, plus the mail/monitoring values selected for the installation.
Provider secrets remain in the encrypted Rails credentials that the master key unlocks. Do not bake
the environment file or master key into the image.

The example is intentionally infrastructure-neutral; it does not configure MySQL, DNS, TLS,
firewalls, SMTP, restart policies, rolling deploys, log collection, or backups. Add those in the
container platform used by the installation. Production Rails assumes SSL has already terminated,
so treat the loopback port as a backend origin only and place it behind a correctly configured HTTPS
proxy. Do not expose this HTTP origin directly to users.

## Required background work

Production uses Solid Queue. Keep one or more `bin/jobs` processes running with access to the
queue database and every queue. The default configuration uses three threads in one process;
`JOB_CONCURRENCY` controls the number of worker processes.

Recurring work is defined in `config/recurring.yml`:

| Job | Schedule | Purpose |
| --- | --- | --- |
| Invoice-source refresh | Every 6 hours | Refresh active/errored sources that remain refreshable, then ratings |
| Invoice-reminder scheduler | Every hour | Find stages due on the current calendar date |
| Payment-promise scheduler | Hourly at minute 20 | Check active promises whose follow-up is due |
| Pending-message reconciler | Hourly at minute 40 | Fail deliveries left pending for more than 2 hours |
| Finished-job cleanup | Hourly at minute 12 | Clear completed Solid Queue records in batches |

Reminder stages use exact calendar dates and intentionally have no catch-up scan. If the scheduler
does not run on a due stage date, that stage is skipped instead of being sent late. Worker uptime
and alerting are therefore product-critical.

Those decisions use `Date.current`. The repository does not set `config.time_zone`, so Rails uses
UTC, and there is no per-account time zone. Before enabling reminders, deliberately keep UTC or set
one installation-wide Rails time zone in the fork; changing it later can change which calendar day
the scheduler considers current.

## System email and providers

Production sign-in and account notification emails use Action Mailer over SMTP. Customer invoice
reminders use each account's connected Gmail address and are not sent through the system SMTP
transport. Workers also poll Gmail about every 15 minutes for History API synchronization and
receipt recovery, so a healthy web process alone is insufficient. Configure both mail paths when
both behaviors are needed.

Register provider callbacks only after the public `HOST` is stable and reachable over HTTPS. See
[Integrations](INTEGRATIONS.md) for scopes, credentials, callbacks, webhook events, and provider
testing.

## Health and monitoring

`GET /up` verifies that the Rails web application boots. It does not verify worker liveness,
recurring schedules, MySQL backup success, Gmail delivery, or provider webhook health.

PaymentReminder supports optional Sentry reporting. Set `SENTRY_DSN` directly, or add it to Rails
credentials and let the included Kamal secrets loader export it:

```yaml
sentry:
  dsn: https://your-sentry-dsn
```

`SENTRY_TRACES_SAMPLE_RATE` defaults to `0.05`. Default PII collection is disabled; do not add OAuth
tokens, email contents, recipient lists, or financial data to Sentry context.

The six critical recurring workflows publish expected-schedule check-ins when Sentry is enabled:

- `schedule-invoice-reminders`
- `refresh-invoice-sources`
- `schedule-payment-promise-follow-ups`
- `reconcile-pending-conversation-messages`
- `poll-gmail-inbound`
- `process-pending-gmail-receipts`

Configure alerts for missed and failed check-ins as well as application exceptions. Also monitor
queue depth, database availability/capacity, provider webhook failures, SMTP bounces/complaints,
certificate expiry, and backup completion.

## Backups and recovery

Back up the MySQL server automatically outside the database host. The primary and queue databases
are critical; include all four Rails databases when backing up at server level. Encrypt backups,
set a retention policy, and rehearse restoring into an isolated environment.

Back up the Rails master key separately from the database and keep a recoverable record of provider
registrations and credential contents, especially `secret_key_base`. A database restore without
credentials containing the same record-encryption key material cannot decrypt stored OAuth tokens.
Do not make the database, master key, and all backup copies recoverable from only one machine or one
operator account.

After a restore, verify:

- migrations and the four database connections;
- one account's users, customers, invoices, schedules, and delivery ledger;
- decryption of provider connections;
- web and worker health;
- system-email delivery;
- provider refresh/webhook behavior in a non-destructive test account.

## Upgrades

Add the source repository as a remote once:

```bash
git remote add upstream https://github.com/arjunrajkumar/payment_reminder.git
```

Then review changes and migrations before deploying a new revision. A typical fork workflow is:

```bash
git fetch upstream
git merge upstream/main
bin/setup --skip-server
bin/rails test
bin/rails test:system
```

Resolve application-specific changes, take a verified production backup, build one immutable image,
run database preparation once, then roll out web and job processes from that same image. Confirm
`/up`, job check-ins, queue processing, provider callbacks, and a real system email after the
deployment.

The [external going-live checklist](GOING_LIVE_CHECKLIST.md) contains a deeper review of DNS,
provider dashboards, policies, backups, and monitoring for the official hosted service. Substitute
the fork's operator, domain, sender, and provider applications throughout; never register its
literal production values for another installation.
