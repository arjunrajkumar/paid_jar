# Developing PaymentReminder

This guide is for people running and changing the application locally. For a hosted installation,
use [Self-hosting and operations](SELF_HOSTING.md).

## Requirements

- Ruby 3.4.5, as pinned by `.ruby-version`
- MySQL 8
- Bundler
- A modern browser
- Google Chrome for system tests
- Node.js 22 and npm only when working in `stripe-app/`
- Stripe CLI plus its Apps plugin only when previewing or uploading the Stripe App

Use mise, asdf, rbenv, or another Ruby version manager. macOS's system Ruby is not compatible with
this application. Building the `mysql2` gem also requires a compiler and MySQL client headers. On
Debian/Ubuntu, the CI-equivalent packages include `build-essential`,
`default-libmysqlclient-dev`, `git`, `libyaml-dev`, and `pkg-config`; on macOS, install the Xcode
Command Line Tools and MySQL through the package manager you use.

## First setup

```bash
git clone https://github.com/YOUR_GITHUB_USERNAME/payment_reminder.git
cd payment_reminder
bin/setup --skip-server
bin/dev
```

Open [http://localhost:3000/signup/new](http://localhost:3000/signup/new). The bare root redirects
signed-out visitors to the official marketing site until a fork changes that branding behavior.

`bin/setup` is safe to run again: it checks or installs gems, prepares the database, and clears old
logs and temporary files. Omit `--skip-server` when you want it to start `bin/dev` automatically.

## MySQL

The default local configuration uses:

```text
socket: /tmp/mysql.sock
username: root
password: blank
development database: paid_jar_development
test database: paid_jar_test
```

If the socket, credentials, host, or database name differs, pass the development URL to both setup
and the server:

```bash
DATABASE_URL=mysql2://root:password@127.0.0.1:3306/paid_jar_development \
  bin/setup --skip-server
DATABASE_URL=mysql2://root:password@127.0.0.1:3306/paid_jar_development bin/dev
```

The password must be URL-encoded if it contains reserved URL characters. Do not export the
development URL globally: Rails will otherwise apply it in the test environment too. Either adapt
`config/database.yml` in a fork or pass a distinct `paid_jar_test` URL to test commands.

## First account and local email

Email signup works without an external mail provider in development. Enter an email address at
`/signup/new`; the verification screen displays the six-character development code, and Letter
Opener opens the generated email locally. Complete the owner name to create the account.

The account workspace is mounted below a generated numeric path such as `/1`. Keep that prefix in
the browser URL: it is how the middleware selects the current account. Authorization verifies
membership in the selected account; the numeric path is not a secret.

Xero signup, Xero/Stripe invoice import, and Gmail delivery require provider credentials. The rest
of the app can boot without them. See [Configuration](CONFIGURATION.md) and
[Integrations](INTEGRATIONS.md).

## Web and background work

Start the Rails development server with:

```bash
bin/dev
```

Development uses Active Job's in-process async adapter, so jobs enqueued by the running web process
execute in that process. The production environment instead uses Solid Queue and must run a
separate `bin/jobs` process. Production-only recurring schedules are defined in
`config/recurring.yml`; they are not a local cron simulator.

Useful commands:

```bash
bin/rails console
bin/rails routes
bin/rails db:migrate
bin/rails db:prepare
```

## Test and quality checks

Run the narrowest test first while developing, then the full relevant checks before opening a
pull request:

```bash
bin/rails test test/models/invoice_test.rb
bin/rails test
bin/rails test:system
bin/rubocop
bin/brakeman --no-pager
bin/importmap audit
```

The GitHub Actions test job prepares the test database and runs application and system tests
together:

```bash
bin/rails db:test:prepare test test:system
```

System tests require Chrome. Test configuration should point at a disposable MySQL database; Rails
recreates it during test preparation.

When local MySQL requires a URL override, keep the test database explicit:

```bash
RAILS_ENV=test \
  DATABASE_URL=mysql2://root:password@127.0.0.1:3306/paid_jar_test \
  bin/rails db:test:prepare test test:system
```

### Stripe App package

The Stripe Dashboard extension is a separate TypeScript package:

```bash
cd stripe-app
npm ci
npm test
npm run typecheck
npm audit --audit-level=high
```

Do not put Rails credentials or Stripe secret keys in this package. See the Stripe section of
[Integrations](INTEGRATIONS.md) before changing its manifest or uploading an App.

## Coding-agent setup prompt

If you use a local coding agent, the following prompt gives it the repository's actual setup and
safety boundaries. Keep secrets in the local editor rather than pasting them into a chat.

```text
Set up PaymentReminder locally.

1. Read README.md and AGENTS.md completely before editing.
2. Activate Ruby 3.4.5 with the version manager available on this machine.
3. Confirm MySQL 8 is running and inspect config/database.yml.
4. Run bin/setup --skip-server.
5. Run bin/rails test and report the result.
6. Start the app with bin/dev and give me the /signup/new localhost URL.
7. If this is my own fork and I need provider credentials, follow
   docs/CONFIGURATION.md. Do not ask me to paste secrets into chat; open the Rails
   credentials editor and wait while I enter them locally.
8. Use docs/INTEGRATIONS.md for provider callbacks and permissions. Do not invent
   credentials or copy the upstream hosted service's values.
```

## Project conventions

- Follow Rails conventions before adding architecture.
- Keep tenant-scoped behavior inside the selected account.
- Preserve provider read-only boundaries and OAuth consent.
- Treat reminder idempotency, provider freshness checks, queue ownership, and the delivery ledger
  as business rules.
- Do not advertise latent schema or model vocabulary as a finished user feature.
- Do not weaken or delete existing tests to make a change pass.
- Never commit credentials, `config/master.key`, provider payloads, or real customer data.

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the pull-request workflow.
