import {fetchStripeSignature} from "@stripe/ui-extension-sdk/utils";
import {getMockContextProps, render} from "@stripe/ui-extension-sdk/testing";
import {Banner, Button} from "@stripe/ui-extension-sdk/ui";
import PaymentReminderSettings from "./PaymentReminderSettings";

jest.mock("@stripe/ui-extension-sdk/utils", () => ({
  fetchStripeSignature: jest.fn(),
}));

const mockedFetchStripeSignature = jest.mocked(fetchStripeSignature);
const mockedFetch = jest.fn();
const productionConstants = {
  PAYMENT_REMINDER_ORIGIN: "https://app.paymentreminderemails.com",
};
const administratorRoles = [
  {type: "builtIn" as const, name: "Administrator"},
];

type RoleWithId = {
  type: "builtIn" | "custom";
  id: string;
  name: string;
};

global.fetch = mockedFetch;

describe("PaymentReminderSettings", () => {
  it("sends signed live-mode Stripe context to the onboarding endpoint", async () => {
    mockedFetchStripeSignature.mockResolvedValue("stripe-signature");
    mockedFetch.mockResolvedValue(
      new Response(
        JSON.stringify({
          onboarding_url:
            "https://app.paymentreminderemails.com/stripe/onboarding/claim-token",
        }),
        {status: 201, headers: {"Content-Type": "application/json"}},
      ),
    );
    const context = getMockContextProps({
      userContext: {
        id: "usr_payment_reminder",
        account: {id: "acct_payment_reminder"},
        roles: administratorRoles,
      },
      environment: {mode: "live", constants: productionConstants},
    });
    const {wrapper, update} = render(
      <PaymentReminderSettings {...context} />,
    );

    wrapper.find(Button)!.trigger("onPress");
    await update();

    expect(mockedFetchStripeSignature).toHaveBeenCalledWith({
      livemode: true,
      stripe_roles: administratorRoles,
    });
    expect(mockedFetch).toHaveBeenCalledWith(
      "https://app.paymentreminderemails.com/stripe/app/onboarding_claims",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Stripe-Signature": "stripe-signature",
        },
        body: JSON.stringify({
          livemode: true,
          stripe_roles: administratorRoles,
          user_id: "usr_payment_reminder",
          account_id: "acct_payment_reminder",
        }),
      },
    );
    expect(
      wrapper.find(Button, {
        href: "https://app.paymentreminderemails.com/stripe/onboarding/claim-token",
      }),
    ).toContainText("Continue to Payment Reminder");
  });

  it("signs test-mode context as not live", async () => {
    mockedFetchStripeSignature.mockResolvedValue("stripe-signature");
    mockedFetch.mockResolvedValue(
      new Response(
        JSON.stringify({
          onboarding_url:
            "https://app.paymentreminderemails.com/stripe/onboarding/claim-token",
        }),
        {status: 200, headers: {"Content-Type": "application/json"}},
      ),
    );
    const context = getMockContextProps({
      userContext: {roles: administratorRoles},
      environment: {mode: "test", constants: productionConstants},
    });
    const {wrapper, update} = render(
      <PaymentReminderSettings {...context} />,
    );

    wrapper.find(Button)!.trigger("onPress");
    await update();

    expect(mockedFetchStripeSignature).toHaveBeenCalledWith({
      livemode: false,
      stripe_roles: administratorRoles,
    });
  });

  it("does not expose an onboarding link from an untrusted origin", async () => {
    mockedFetchStripeSignature.mockResolvedValue("stripe-signature");
    mockedFetch.mockResolvedValue(
      new Response(
        JSON.stringify({
          onboarding_url: "https://attacker.example/claim-token",
        }),
        {status: 200, headers: {"Content-Type": "application/json"}},
      ),
    );
    const context = getMockContextProps({
      userContext: {roles: administratorRoles},
      environment: {constants: productionConstants},
    });
    const {wrapper, update} = render(
      <PaymentReminderSettings {...context} />,
    );

    wrapper.find(Button)!.trigger("onPress");
    await update();
    await update();

    expect(
      wrapper.find(Banner, {title: "We couldn't start setup"}),
    ).not.toBeNull();
    expect(
      wrapper.findAll(Button).some((button) => Boolean(button.prop("href"))),
    ).toBe(false);
  });

  it("uses an overridden origin for external testing", async () => {
    mockedFetchStripeSignature.mockResolvedValue("stripe-signature");
    mockedFetch.mockResolvedValue(
      new Response(
        JSON.stringify({
          onboarding_url: "https://external-test.example/onboarding/claim-token",
        }),
        {status: 201, headers: {"Content-Type": "application/json"}},
      ),
    );
    const context = getMockContextProps({
      userContext: {roles: administratorRoles},
      environment: {
        constants: {
          PAYMENT_REMINDER_ORIGIN: "https://external-test.example",
        },
      },
    });
    const {wrapper, update} = render(
      <PaymentReminderSettings {...context} />,
    );

    wrapper.find(Button)!.trigger("onPress");
    await update();

    expect(mockedFetch).toHaveBeenCalledWith(
      "https://external-test.example/stripe/app/onboarding_claims",
      expect.any(Object),
    );
    expect(
      wrapper.find(Button, {
        href: "https://external-test.example/onboarding/claim-token",
      }),
    ).not.toBeNull();
  });

  it("shows an error when the backend request fails", async () => {
    mockedFetchStripeSignature.mockResolvedValue("stripe-signature");
    mockedFetch.mockRejectedValue(new Error("network unavailable"));
    const context = getMockContextProps({
      userContext: {roles: administratorRoles},
      environment: {constants: productionConstants},
    });
    const {wrapper, update} = render(
      <PaymentReminderSettings {...context} />,
    );

    wrapper.find(Button)!.trigger("onPress");
    await update();
    await update();

    expect(
      wrapper.find(Banner, {title: "We couldn't start setup"}),
    ).not.toBeNull();
  });

  it("does not make a request without Stripe user context", async () => {
    const context = getMockContextProps({
      userContext: {id: "", roles: administratorRoles},
      environment: {constants: productionConstants},
    });
    const {wrapper, update} = render(
      <PaymentReminderSettings {...context} />,
    );

    wrapper.find(Button)!.trigger("onPress");
    await update();

    expect(mockedFetchStripeSignature).not.toHaveBeenCalled();
    expect(mockedFetch).not.toHaveBeenCalled();
    expect(
      wrapper.find(Banner, {title: "We couldn't start setup"}),
    ).not.toBeNull();
  });

  it("does not make a request without Stripe account context", async () => {
    const context = getMockContextProps({
      userContext: {account: {id: ""}, roles: administratorRoles},
      environment: {constants: productionConstants},
    });
    const {wrapper, update} = render(
      <PaymentReminderSettings {...context} />,
    );

    wrapper.find(Button)!.trigger("onPress");
    await update();

    expect(mockedFetchStripeSignature).not.toHaveBeenCalled();
    expect(mockedFetch).not.toHaveBeenCalled();
    expect(
      wrapper.find(Banner, {title: "We couldn't start setup"}),
    ).not.toBeNull();
  });

  it.each(["admin", "super_admin"])(
    "accepts the stable %s role id when Stripe provides one",
    (roleId) => {
      const role: RoleWithId = {
        type: "builtIn",
        id: roleId,
        name: "Renamed administrator",
      };
      const context = getMockContextProps({
        userContext: {roles: [role]},
        environment: {constants: productionConstants},
      });
      const {wrapper} = render(<PaymentReminderSettings {...context} />);

      expect(wrapper.find(Button)).toContainText("Connect Payment Reminder");
      expect(
        wrapper.find(Banner, {title: "Administrator access required"}),
      ).toBeNull();
    },
  );

  it("does not trust an administrator display name when a non-admin role id is present", () => {
    const role: RoleWithId = {
      type: "builtIn",
      id: "developer",
      name: "Administrator",
    };
    const context = getMockContextProps({
      userContext: {roles: [role]},
      environment: {constants: productionConstants},
    });
    const {wrapper} = render(<PaymentReminderSettings {...context} />);

    expect(
      wrapper.find(Banner, {title: "Administrator access required"}),
    ).not.toBeNull();
    expect(wrapper.find(Button)).toBeNull();
  });
});
