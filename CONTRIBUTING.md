# Contributing to PaymentReminder

Thanks for helping improve PaymentReminder. Bug reports, documentation fixes, tests, and focused
product changes are welcome.

## Before changing code

1. Search the existing issues and pull requests for related work.
2. For a substantial workflow or product-policy change, open an issue describing the user problem
   and intended behavior before investing in a large implementation.
3. Read [README.md](README.md), [the development guide](docs/DEVELOPMENT.md), and
   [the capability audit](docs/CAPABILITY_AUDIT.md).
4. If you are using a coding agent, also read [AGENTS.md](AGENTS.md).

Never post credentials, OAuth tokens, webhook payloads, customer financial information, recipient
lists, or real email content in an issue, pull request, test fixture, or screenshot.
Report suspected vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Set up the application

PaymentReminder requires Ruby 3.4.5 and MySQL 8:

```bash
git clone https://github.com/YOUR_GITHUB_USERNAME/payment_reminder.git
cd payment_reminder
bin/setup --skip-server
bin/dev
```

Open `http://localhost:3000/signup/new`. See [Developing PaymentReminder](docs/DEVELOPMENT.md) for
database overrides, local email, provider setup, and Stripe App development.

## Make a change

- Follow normal Rails conventions and keep changes small enough to review.
- Keep high-level methods readable and move complex details into intention-revealing helpers.
- Preserve account scoping on every customer-owned record and request.
- Use the application's domain operations for reminders, promises, providers, and admin actions;
  do not bypass validation, idempotency, or the delivery ledger with raw updates.
- Treat accounting providers as read-only unless a separately reviewed feature explicitly changes
  that boundary.
- Do not present latent models or message types as a user-facing feature until the complete flow
  exists.
- Add or update tests for bug fixes and important confirmed business behavior.
- Do not weaken, delete, or rewrite an existing test simply to make an implementation pass. When a
  test appears wrong, explain the conflict before changing it.

## Run checks

Start with the narrowest relevant test, then run the complete application suite:

```bash
bin/rails test test/models/invoice_test.rb
bin/rails test
```

For browser behavior, also run:

```bash
bin/rails test:system
```

Run the static checks used in CI:

```bash
bin/rubocop
bin/brakeman --no-pager
bin/importmap audit
```

When changing `stripe-app/`, use Node.js 22 and run:

```bash
cd stripe-app
npm ci
npm test
npm run typecheck
npm audit --audit-level=high
```

Documentation-only changes do not need the application test suite, but local links and example
commands should still be checked.

## Open a pull request

Include:

- the user or operator problem being solved;
- a concise description of the behavior change;
- screenshots for visible UI changes;
- migrations, deployment changes, provider permissions, or new secrets called out explicitly;
- tests run and their results;
- any known follow-up work that is genuinely outside the pull request.

Keep unrelated formatting or refactors out of the same pull request. Do not commit generated logs,
temporary screenshots, `node_modules`, decrypted credentials, or `config/master.key`.

## License

By contributing to this repository, you agree that your contributions are licensed under the
[GNU Affero General Public License v3.0](LICENSE), the same license used by PaymentReminder.
