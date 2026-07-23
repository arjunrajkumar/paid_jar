# Platform administration

PaymentReminder includes a global Madmin console for the application developer or hosted-service
operator. It is not the same thing as the `owner` or `admin` role inside a customer account.

The console is mounted at `/madmin` without an account prefix. A platform administrator can see
across every tenant; a normal account owner can only operate inside that account.

## Grant access

Allowlist exact, normalized sign-in email addresses in Rails credentials:

```bash
bin/rails credentials:edit
```

```yaml
platform_admin:
  email_addresses:
    - operator@example.com
```

You can also set a comma- or whitespace-separated environment variable:

```text
PLATFORM_ADMIN_EMAIL_ADDRESSES=operator@example.com,backup-operator@example.com
```

Addresses from credentials and the environment variable are combined, normalized, and
deduplicated. The allowlist fails closed when both are empty. Restart the application after
changing it, sign in with an allowlisted identity, and open `<HOST>/madmin`. Merely being an account
owner does not grant platform access. Remove an address from both sources when revoking an
operator.

Use individual operator identities, not a shared mailbox. Protect those identities and the Rails
master key with the strongest controls available to the deployment.

The panel uses the application's normal email-code/Xero authentication session. It has no separate
admin MFA, step-up prompt, or built-in session expiry, and the signed session cookie is permanent
until revoked or cleared. Protect operator mailboxes and Xero identities, restrict `/madmin` at the
network or identity-proxy layer where appropriate, and add MFA/session-expiry controls before using
the panel in a higher-risk deployment.

## What the operator can see

The panel exposes global indexes and detail pages for:

- every account and the human/system users associated with it;
- sign-in identities, external identities, browser sessions, and outstanding sign-in codes;
- customers, additional reminder recipients, debtor segments, and imported invoices;
- Xero and Stripe invoice sources, source state, sync errors, install claims, and webhook events;
- Gmail connection state and configured sender identity, plus durable mailbox screening receipts
  and their processing state;
- reminder schedules, reminders, suppressions, and message delivery state;
- payment promises and their follow-up state;
- notification subscriptions and the platform-admin event ledger.

OAuth access/refresh tokens, raw OAuth payloads, magic-link codes, token digests, Stripe claim
tokens/digests, raw provider invoice records, and signed webhook payloads are omitted. Recipient
lists and message content are excluded from indexes and search, although an individual message
record can show the delivery detail needed for support.

## What the operator can do

The panel provides explicit, domain-aware actions to:

- edit an account's business name, reminder sender settings, automatic-reminder setting, debtor
  thresholds, and persisted schedules;
- edit a human user's name, role, and notification preferences;
- suspend or reactivate a human user;
- revoke another browser session or an outstanding sign-in code;
- act as any active human user in that user's exact account, then stop impersonating;
- refresh all debtor ratings in an account or one customer's rating;
- run today's reminder scheduler for one account;
- queue a Xero or Stripe invoice refresh;
- disconnect an invoice source and disconnect an account's Gmail sender;
- retry a pending or failed webhook event;
- requeue a terminally failed Gmail screening receipt after diagnosing the provider or processing
  failure;
- edit or remove an additional customer reminder recipient;
- send a one-off reminder for an outstanding invoice;
- record a customer's payment promise with an operator note;
- mark an active promise fulfilled or cancelled;
- enqueue a promise's normal due-follow-up check.

The one-off reminder is an explicit operator override: it can run when automatic reminders are
off and does not apply the scheduled stage date, active-promise suppression, or 48-hour automatic
cooldown. It still refreshes the provider invoice first and requires the invoice to remain
outstanding, an active matching Gmail sender, valid recipients, and no other pending delivery.

Impersonation does not expose system users or turn an inactive user into an active one. A persistent
banner identifies the impersonated account and offers a return to the operator console.

## Deliberate safety boundaries

The admin console is broad, but it is not unrestricted database access. Generic create, update, or
delete controls are blocked for high-risk and provider-owned records. The operator cannot use raw
forms to:

- fabricate, delete, or reassign imported provider invoices and customers;
- reassign external sign-in identities;
- create or delete customer accounts;
- create arbitrary users outside a deliberate account workflow;
- expose or rewrite OAuth tokens and signing material;
- alter or delete Gmail screening receipts outside the explicit terminal-failure retry workflow;
- bypass provider authorization or consent.

Those limits preserve tenant integrity, provider truth, validation, delivery idempotency, and the
audit trail. Impersonation selects the user's exact account and uses the normal account UI, but the
signed-in platform administrator retains elevated account-admin authorization even when acting as
a member. It is an operator support mode, not a faithful simulation of that user's permissions.

Provider-side actions still require a real provider user:

- Xero must be connected or reconnected through Xero OAuth.
- Stripe must be installed or authorized from the controlling Stripe account; uninstall still
  happens in Stripe.
- Gmail must be connected or reconnected by the mailbox owner through Google OAuth.

After valid consent exists, an operator can request supported sync, delivery, settings, and
diagnostic actions through the console.

## Operator audit trail

The Madmin controller records POST, PATCH, PUT, and DELETE requests that finish with a redirect.
That includes normal successful mutations and blocked or failed attempts that redirect. A
validation failure rendered in place is not currently recorded. Each recorded
`PlatformAdminEvent` contains:

- the signed-in administrator;
- action name;
- target record;
- affected account when one can be identified;
- timestamp;
- names of changed fields.

Submitted values and secrets are not copied into that ledger. Browse it in Madmin when reviewing a
support intervention. The ledger covers requests handled by the Madmin controller. Starting and
stopping impersonation are recorded, but mutations made through ordinary account controllers while
impersonating are not separately written to `PlatformAdminEvent`.

If a terminal Gmail receipt is reset for retry but its processing job cannot be enqueued, the
controller records a separate enqueue-failure event containing the error class, not its potentially
sensitive message, before propagating the failure.

## Operating practice

- Keep the allowlist as small as possible and remove departed operators immediately.
- Do not leave a browser impersonating a customer user.
- Use explicit panel actions instead of editing production data in a Rails console.
- Verify the account, source, invoice, and recipients before sending a manual reminder.
- Treat message content and customer financial records as sensitive even when they are visible for
  support.
- Monitor the event ledger and application errors after state-changing actions.

For the full user/admin capability matrix and remaining gaps, see
[the capability audit](CAPABILITY_AUDIT.md).
