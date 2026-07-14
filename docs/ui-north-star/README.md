# Receivables UI north star

Captured on July 14, 2026 with disposable test-only customer and invoice data.

The receivables inbox is the only current authenticated receivables screen. Its
`after-home-` screenshots are the active product baseline: every displayed
value comes from persisted customers and invoices.

Until communication is persisted, the inbox should show only:

- customer identity;
- outstanding, overdue, open, paid, and uncollectible invoice facts;
- payer segments persisted after a full invoice sync and calculated from the
  latest 12 paid or uncollectible outcomes. Paid outcomes require both due and
  payment dates; any uncollectible outcome in the window is unreliable.

Customer status follows this precedence: overdue, outstanding, uncollectible,
open with no balance due, then paid.

Do not add reminder, reply, schedule, dispute, or conversation claims to the
inbox until the corresponding records and workflow exist.

## Inbox before cleanup

![Receivables inbox before cleanup](before-home-inbox.png)

![Remaining inbox states before cleanup](before-home-inbox-bottom.png)

## Current persisted-facts baseline

![Receivables inbox after cleanup](after-home-inbox.png)

![Remaining inbox states after cleanup](after-home-inbox-bottom.png)

## Archived customer-detail reference

There is currently no customer-detail route or screen. These captures are kept
only as visual reference for a future customer-detail feature. The conversation
examples are prototypes and must not return until their data and workflow are
persisted.

![Harbor and Co before cleanup](before-customer-harbor-top.png)

![Prototype Harbor conversation](before-customer-harbor-conversation.png)

![Nat Dogre before cleanup](before-customer-nat-dogre-top.png)

![Prototype Nat Dogre conversation](before-customer-nat-dogre-conversation.png)

![Persisted-facts Harbor concept](after-customer-harbor.png)

![Persisted-facts Nat Dogre concept](after-customer-nat-dogre.png)
