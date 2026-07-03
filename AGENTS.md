# Agent Guidelines

Read this file before editing PaidJar.

## Product Context

- PaidJar is an open-source, self-hostable Rails app for accounts receivable.
- The product promise is an AI accounts-receivable inbox that helps freelancers and small teams get paid faster.
- Keep public-facing copy clear and product-focused. Do not expose private implementation details unless the user explicitly asks for technical docs.
- This app is AGPL-3.0 licensed. Keep license-related language consistent with `LICENSE`, `README.md`, and `CONTRIBUTING.md`.

## Stack

- Ruby 3.4.5
- Rails 8
- SQLite
- Hotwire: Turbo and Stimulus
- Importmap for JavaScript
- Propshaft for assets
- Solid Cache, Solid Queue, and Solid Cable
- Minitest, Capybara, and Selenium
- Kamal and Docker for deployment

## Engineering Rules

- Follow Rails conventions before adding custom architecture.
- Keep changes small, direct, and easy to review.
- Prefer plain Rails objects, Active Record models, controllers, jobs, and mailers over new abstractions until the app clearly needs them.
- For non-trivial product or workflow changes, first describe the intended flow in clear method-level steps before implementing.
- Use TDD for important business flows and bug fixes: write or identify the failing test first, then make it pass.
- Do not change, weaken, or delete existing tests without explicitly confirming with the user first.
- When code and a test disagree, assume the test is the source of truth and fix the code. If the test appears wrong, stop and ask.
- Do not leave TODOs, placeholders, or half-implemented behavior.
- If you do not know something, say so instead of guessing.

## Verification

- For code changes, run the narrowest useful test command first.
- Before handing off a meaningful change, prefer running:

```bash
bin/rails test
```

- For changes that touch system tests or browser behavior, also run:

```bash
bin/rails test:system
```

- For style-only documentation changes, tests are not required.

## Permissions

- Always ask before committing.
- Always ask before pushing to GitHub.
- Always ask before running `kamal deploy` or any production deployment command.
- Do not rewrite git history unless the user explicitly asks for it.
- Do not merge Dependabot or outside contributor PRs while checks are failing.
