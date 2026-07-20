import {useState} from "react";
import type {ExtensionContextValue} from "@stripe/ui-extension-sdk/context";
import {fetchStripeSignature} from "@stripe/ui-extension-sdk/utils";
import {
  Banner,
  Box,
  Button,
  Inline,
  SettingsView,
} from "@stripe/ui-extension-sdk/ui";

type Status = "idle" | "submitting" | "ready" | "error";

type OnboardingClaimResponse = {
  onboarding_url?: unknown;
};

type RoleWithOptionalId = NonNullable<
  ExtensionContextValue["userContext"]["roles"]
>[number] & {id?: string};

const administratorRoleIds = new Set(["admin", "super_admin"]);
const administratorRoleNames = new Set([
  "Administrator",
  "Super Administrator",
]);

function isAdministratorRole(role: RoleWithOptionalId): boolean {
  if (role.type !== "builtIn") {
    return false;
  }

  if (Object.prototype.hasOwnProperty.call(role, "id")) {
    return typeof role.id === "string" && administratorRoleIds.has(role.id);
  }

  return administratorRoleNames.has(role.name);
}

function configuredOrigin(
  constants: ExtensionContextValue["environment"]["constants"],
): string {
  if (!constants || typeof constants !== "object" || Array.isArray(constants)) {
    throw new Error("The Payment Reminder origin is not configured.");
  }

  const value = (constants as Record<string, unknown>).PAYMENT_REMINDER_ORIGIN;

  if (typeof value !== "string") {
    throw new Error("The Payment Reminder origin is not configured.");
  }

  const origin = new URL(value);

  if (origin.protocol !== "https:") {
    throw new Error("The Payment Reminder origin must use HTTPS.");
  }

  return origin.origin;
}

function verifiedOnboardingUrl(
  response: OnboardingClaimResponse,
  paymentReminderOrigin: string,
): string {
  if (typeof response.onboarding_url !== "string") {
    throw new Error("The onboarding response did not include a URL.");
  }

  const onboardingUrl = new URL(response.onboarding_url);

  if (
    onboardingUrl.protocol !== "https:" ||
    onboardingUrl.origin !== paymentReminderOrigin
  ) {
    throw new Error("The onboarding response included an untrusted URL.");
  }

  return onboardingUrl.toString();
}

export default function PaymentReminderSettings({
  userContext,
  environment,
}: ExtensionContextValue) {
  const [status, setStatus] = useState<Status>("idle");
  const [onboardingUrl, setOnboardingUrl] = useState<string>();
  const canAdministerAccount = userContext.roles?.some(isAdministratorRole);

  const createOnboardingClaim = async () => {
    const userId = userContext.id;
    const accountId = userContext.account.id;
    const stripeRoles = userContext.roles?.map((role) => ({...role}));

    if (!userId || !accountId || !stripeRoles?.some(isAdministratorRole)) {
      setStatus("error");
      return;
    }

    setStatus("submitting");

    try {
      const paymentReminderOrigin = configuredOrigin(environment.constants);
      const onboardingClaimsUrl = new URL(
        "/stripe/app/onboarding_claims",
        paymentReminderOrigin,
      ).toString();
      const signedPayload = {
        livemode: environment.mode === "live",
        stripe_roles: stripeRoles,
      };
      const signature = await fetchStripeSignature(signedPayload);
      const response = await fetch(onboardingClaimsUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Stripe-Signature": signature,
        },
        body: JSON.stringify({
          ...signedPayload,
          user_id: userId,
          account_id: accountId,
        }),
      });

      if (!response.ok) {
        throw new Error("Payment Reminder rejected the onboarding request.");
      }

      const responseBody = (await response.json()) as OnboardingClaimResponse;
      setOnboardingUrl(
        verifiedOnboardingUrl(responseBody, paymentReminderOrigin),
      );
      setStatus("ready");
    } catch {
      setOnboardingUrl(undefined);
      setStatus("error");
    }
  };

  return (
    <SettingsView
      statusMessage={status === "ready" ? "Ready to connect" : undefined}
    >
      <Box css={{stack: "y", gap: "large", maxWidth: 640}}>
        <Box css={{stack: "y", gap: "xsmall"}}>
          <Inline css={{font: "heading"}}>Connect Payment Reminder</Inline>
          <Inline css={{color: "secondary"}}>
            Link this Stripe account to Payment Reminder to import invoices and
            keep their payment status current.
          </Inline>
        </Box>

        {status === "error" && (
          <Banner
            type="critical"
            title="We couldn't start setup"
            description="Try again. If the problem continues, contact Payment Reminder support."
          />
        )}

        {!canAdministerAccount ? (
          <Banner
            type="caution"
            title="Administrator access required"
            description="Ask a Stripe Administrator or Super Administrator to connect this account."
          />
        ) : onboardingUrl ? (
          <Box css={{stack: "y", gap: "medium"}}>
            <Banner
              title="Your Stripe account is verified"
              description="Continue to Payment Reminder to sign in or create your account."
            />
            <Button type="primary" href={onboardingUrl} target="_blank">
              Continue to Payment Reminder
            </Button>
          </Box>
        ) : (
          <Button
            type="primary"
            pending={status === "submitting"}
            onPress={createOnboardingClaim}
          >
            Connect Payment Reminder
          </Button>
        )}
      </Box>
    </SettingsView>
  );
}
