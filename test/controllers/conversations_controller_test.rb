require "test_helper"

class ConversationsControllerTest < ActionDispatch::IntegrationTest
  test "Inbox requires an account session" do
    get conversations_url

    assert_redirected_to new_session_url(script_name: nil)
  end

  test "index and detail show account-scoped persisted conversation messages" do
    account = sign_up_and_complete
    invoice = create_invoice(account)
    conversation = Conversation.for_invoice!(invoice:)
    outbound = conversation.conversation_messages.create!(
      account:,
      invoice:,
      direction: :outbound,
      kind: :scheduled_reminder,
      status: :sent,
      sent_at: Time.zone.local(2026, 7, 23, 9),
      subject: "Invoice reminder",
      body: "Please review invoice INV-INBOX."
    )
    inbound = conversation.conversation_messages.create!(
      account:,
      invoice:,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.zone.local(2026, 7, 23, 10),
      from_address: invoice.customer.email,
      subject: "Re: Invoice reminder",
      body: "<script>alert('unsafe')</script>\nI have a question.",
      matching_status: :matched,
      matching_method: :invoice_reference
    )
    conversation.update!(attention_required_at: inbound.received_at)

    get conversations_url

    assert_response :success
    assert_select "h1", "Inbox"
    assert_equal(
      [ "Inbox 1", "Invoices", "Settings" ],
      css_select("#application-navigation-links > a").map { |link| link.text.squish }
    )
    assert_select ".app-nav-badge[aria-label='1 conversation needs attention']", "1"
    assert_select ".app-conversation-row", count: 1
    assert_select "a[href=?]", conversation_path(conversation)

    get conversation_url(conversation)

    assert_response :success
    assert_select ".app-conversation-message", count: 2
    bodies = css_select(".app-conversation-message__body").map(&:text)
    assert_includes bodies, outbound.body
    assert_includes bodies, inbound.body
    assert_select ".app-conversation-message__body script", count: 0
    assert_select "form[action=?]", conversation_acknowledgement_path(conversation)
  end

  test "linked source redirects to the canonical detail" do
    account = sign_up_and_complete(email_address: "linked-inbox@example.com")
    invoice = create_invoice(account)
    canonical = Conversation.for_invoice!(invoice:)
    source = account.conversations.create!(canonical_conversation: canonical)
    source.conversation_messages.create!(
      account:,
      invoice:,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.current,
      matching_status: :unmatched,
      matching_method: :none
    )

    get conversation_url(source)

    assert_redirected_to conversation_path(canonical)
  end

  test "does not offer manual matching for linked or invoice-backed messages" do
    account = sign_up_and_complete(email_address: "match-action-eligibility@example.com")
    invoice = create_invoice(account)
    connection = account.create_email_connection!(
      provider: :gmail,
      provider_account_id: "match-action-provider",
      connected_email: "billing-match-action@example.com",
      access_token: "access-token",
      refresh_token: "refresh-token",
      scopes: EmailConnection::Gmailable::REQUIRED_SCOPES,
      status: :active
    )
    canonical = Conversation.for_invoice!(invoice:)
    source = account.conversations.create!(canonical_conversation: canonical)
    linked_message = source.conversation_messages.create!(
      account:,
      invoice:,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.current,
      matching_status: :unmatched,
      matching_method: :none
    )
    invoice_review = canonical.conversation_messages.create!(
      account:,
      invoice:,
      email_connection: connection,
      email_connection_generation: connection.credential_generation,
      provider_account_id: connection.provider_account_id,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: 1.minute.from_now,
      matching_status: :ambiguous,
      matching_method: :invoice_reference,
      review_required: true
    )

    get conversation_url(canonical)

    assert_response :success
    assert_select "a[href*='/match']", count: 0
    assert_select "form[action=?]", conversation_review_path(canonical, invoice_review), count: 1
    assert_select "input[value=?]", linked_message.id.to_s, count: 0
  end

  test "a collapsed sibling message is visible and reviewable from the owning detail" do
    account = sign_up_and_complete(email_address: "collapsed-review-action@example.com")
    invoice = create_invoice(account)
    owner, sibling, first, later = create_collapsed_review_messages(
      account,
      customer_email: invoice.customer.email,
      suffix: "review-action"
    )

    get conversation_url(owner)

    assert_response :success
    assert_select ".app-conversation-message__body", text: first.body
    assert_select ".app-conversation-message__body", text: later.body
    assert_select "form[action=?]", conversation_review_path(owner, later), count: 1

    patch conversation_review_url(owner, later), params: {
      review: {
        outcome: "no_match_needed",
        work_unit_token: conversation_work_unit_token(owner)
      }
    }

    assert_redirected_to conversation_path(owner)
    assert_not_predicate first.reload, :awaiting_review?
    assert_not_predicate later.reload, :awaiting_review?
    assert_nil owner.reload.attention_required_at
    assert_nil sibling.reload.attention_required_at
  end

  test "a collapsed sibling message can be manually matched from the owning detail" do
    account = sign_up_and_complete(email_address: "collapsed-match-action@example.com")
    invoice = create_invoice(account)
    owner, sibling, _first, later = create_collapsed_review_messages(
      account,
      customer_email: invoice.customer.email,
      suffix: "match-action"
    )

    post conversation_match_url(owner), params: {
      match: {
        message_id: later.id,
        invoice_id: invoice.id,
        work_unit_token: conversation_work_unit_token(owner)
      }
    }

    canonical = Conversation.for_invoice!(invoice:)
    assert_redirected_to conversation_path(canonical)
    assert_equal canonical, owner.reload.canonical_conversation
    assert_equal canonical, sibling.reload.canonical_conversation
    assert_predicate later.reload, :review_outcome_manual_match?
  end

  test "another account conversation is not disclosed" do
    sign_up_and_complete(email_address: "scoped-inbox@example.com")
    other_account = Account.create!(name: "Other Inbox Account")
    other_conversation = other_account.conversations.create!

    get conversation_url(other_conversation)

    assert_response :not_found
  end

  test "unmatched Inbox rows identify the latest inbound sender" do
    account = sign_up_and_complete(email_address: "unmatched-sender@example.com")
    conversation = account.conversations.create!
    conversation.conversation_messages.create!(
      account:,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.current,
      from_address: "sender-visible@example.com",
      subject: "Unmatched question",
      matching_status: :unmatched,
      matching_method: :none
    )

    get conversations_url

    assert_response :success
    assert_select ".app-conversation-row__identity strong", "sender-visible@example.com"
  end

  test "matching resolves submitted invoice IDs through the current account" do
    account = sign_up_and_complete(email_address: "match-scope@example.com")
    conversation = account.conversations.create!
    message = conversation.conversation_messages.create!(
      account:,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.current,
      matching_status: :unmatched,
      matching_method: :none
    )

    post conversation_match_url(conversation), params: {
      match: {
        message_id: message.id,
        invoice_id: invoices(:xero_invoice).id,
        work_unit_token: conversation_work_unit_token(conversation)
      }
    }

    assert_response :not_found
    assert_nil conversation.reload.canonical_conversation
  end

  test "reply submission rejects a signed composer whose displayed recipient changed" do
    account = sign_up_and_complete(email_address: "stale-composer@example.com")
    invoice = create_invoice(account)
    account.update!(invoice_reminder_from_email: "billing-stale-composer@example.com")
    connection = account.create_email_connection!(
      provider: :gmail,
      provider_account_id: "stale-composer-provider",
      connected_email: account.invoice_reminder_from_email,
      access_token: "access-token",
      refresh_token: "refresh-token",
      scopes: EmailConnection::Gmailable::REQUIRED_SCOPES,
      status: :active
    )
    conversation = Conversation.for_invoice!(invoice:)
    anchor = conversation.conversation_messages.create!(
      account:,
      invoice:,
      email_connection: connection,
      email_connection_generation: connection.credential_generation,
      provider_account_id: connection.provider_account_id,
      provider_message_id: "stale-composer-anchor",
      provider_thread_id: "stale-composer-thread",
      internet_message_id: "<stale-composer-anchor@example.com>",
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.current,
      from_address: invoice.customer.email,
      matching_status: :matched,
      matching_method: :gmail_thread
    )
    get conversation_url(conversation)
    composer_token = css_select(
      "input[name='reply[composer_token]']"
    ).sole.attributes.fetch("value").value
    idempotency_key = css_select(
      "input[name='reply[idempotency_key]']"
    ).sole.attributes.fetch("value").value
    invoice.customer.update!(email: "changed-after-render@example.com")

    assert_no_difference -> { ConversationMessage.kind_manual_reply.count } do
      post conversation_replies_url(conversation), params: {
        reply: {
          anchor_message_id: anchor.id,
          body: "Do not send to a different recipient.",
          idempotency_key:,
          composer_token:
        }
      }
    end

    assert_redirected_to conversation_path(conversation)
    assert_equal "This reply form is stale. Refresh and try again.", flash[:alert]
  end

  test "ordinary account members can mark shared Inbox attention handled" do
    account = sign_up_and_complete(email_address: "member-inbox@example.com")
    user = account.users.active.sole
    user.update!(role: :member)
    conversation = account.conversations.create!(attention_required_at: Time.current)
    conversation.conversation_messages.create!(
      account:,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.current,
      matching_status: :unmatched,
      matching_method: :none
    )

    post conversation_acknowledgement_url(conversation), params: {
      acknowledgement: {
        work_unit_token: conversation_work_unit_token(conversation)
      }
    }

    assert_redirected_to conversation_path(conversation)
    assert_nil conversation.reload.attention_required_at
    event = conversation.conversation_events.kind_conversation_attention_cleared.sole
    assert_equal user, event.actor_user
    assert_predicate event, :actor_kind_user?
  end

  test "stale review submission makes no changes" do
    account = sign_up_and_complete(email_address: "stale-review@example.com")
    invoice = create_invoice(account)
    owner, _sibling, first, later = create_collapsed_review_messages(
      account,
      customer_email: invoice.customer.email,
      suffix: "stale-review"
    )
    get conversation_url(owner)
    token = hidden_input_value(
      "form[action='#{conversation_review_path(owner, later)}'] " \
        "input[name='review[work_unit_token]']"
    )
    new_conversation = account.conversations.create!
    added = create_collapsed_review_message(
      new_conversation,
      connection: first.email_connection,
      customer_email: invoice.customer.email,
      provider_message_id: "stale-review-added",
      body: "Arrived after review form render",
      received_at: Time.current
    )

    assert_no_difference -> { ConversationEvent.count } do
      patch conversation_review_url(owner, later), params: {
        review: {
          outcome: "no_match_needed",
          work_unit_token: token
        }
      }
    end

    assert_redirected_to conversation_path(owner)
    assert_equal "Conversation changed; refresh and try again.", flash[:alert]
    assert_predicate first.reload, :awaiting_review?
    assert_predicate later.reload, :awaiting_review?
    assert_predicate added.reload, :awaiting_review?
  end

  test "stale manual match submission makes no changes" do
    account = sign_up_and_complete(email_address: "stale-match@example.com")
    invoice = create_invoice(account)
    owner, sibling, first, later = create_collapsed_review_messages(
      account,
      customer_email: invoice.customer.email,
      suffix: "stale-match"
    )
    get new_conversation_match_url(owner, message_id: later.id)
    token = hidden_input_value("input[name='match[work_unit_token]']")
    added_conversation = account.conversations.create!
    added = create_collapsed_review_message(
      added_conversation,
      connection: first.email_connection,
      customer_email: invoice.customer.email,
      provider_message_id: "stale-match-added",
      body: "Arrived after match form render",
      received_at: Time.current
    )

    assert_no_difference -> { ConversationEvent.count } do
      post conversation_match_url(owner), params: {
        match: {
          message_id: later.id,
          invoice_id: invoice.id,
          work_unit_token: token
        }
      }
    end

    assert_response :unprocessable_entity
    assert_select "#flash", text: "Conversation changed; refresh and try again."
    assert_nil owner.reload.canonical_conversation
    assert_nil sibling.reload.canonical_conversation
    assert_nil added_conversation.reload.canonical_conversation
    assert_predicate added.reload, :awaiting_review?
  end

  test "stale acknowledgement submission leaves attention and audit unchanged" do
    account = sign_up_and_complete(email_address: "stale-handled@example.com")
    conversation = account.conversations.create!(
      attention_required_at: Time.zone.local(2026, 7, 23, 10)
    )
    conversation.conversation_messages.create!(
      account:,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.zone.local(2026, 7, 23, 10),
      matching_status: :unmatched,
      matching_method: :none
    )
    get conversation_url(conversation)
    token = hidden_input_value(
      "form[action='#{conversation_acknowledgement_path(conversation)}'] " \
        "input[name='acknowledgement[work_unit_token]']"
    )
    conversation.conversation_messages.create!(
      account:,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.zone.local(2026, 7, 23, 11),
      matching_status: :unmatched,
      matching_method: :none
    )

    assert_no_difference -> { ConversationEvent.count } do
      post conversation_acknowledgement_url(conversation), params: {
        acknowledgement: { work_unit_token: token }
      }
    end

    assert_redirected_to conversation_path(conversation)
    assert_equal "Conversation changed; refresh and try again.", flash[:alert]
    assert_equal Time.zone.local(2026, 7, 23, 10),
      conversation.reload.attention_required_at
  end

  private
    def hidden_input_value(selector)
      css_select(selector).sole.attributes.fetch("value").value
    end

    def sign_up_and_complete(email_address: "inbox-owner@example.com")
      post signup_url, params: { signup: { email_address: } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Inbox Owner" } }

      Identity.find_by!(email_address:).accounts.first
    end

    def create_invoice(account)
      source = account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: "inbox-source-#{account.id}"
      )
      customer = source.customers.create!(
        account:,
        external_id: "inbox-customer-#{account.id}",
        name: "Inbox Customer",
        email: "customer-#{account.id}@example.com"
      )
      source.invoices.create!(
        account:,
        customer:,
        external_id: "inbox-invoice-#{account.id}",
        number: "INV-INBOX",
        status: :open
      )
    end

    def create_collapsed_review_messages(account, customer_email:, suffix:)
      connection = account.create_email_connection!(
        provider: :gmail,
        provider_account_id: "collapsed-provider-#{suffix}",
        connected_email: "billing-#{suffix}@example.com",
        access_token: "access-token",
        refresh_token: "refresh-token",
        scopes: EmailConnection::Gmailable::REQUIRED_SCOPES,
        status: :active
      )
      owner = account.conversations.create!
      sibling = account.conversations.create!
      first = create_collapsed_review_message(
        owner,
        connection:,
        customer_email:,
        provider_message_id: "collapsed-first-#{suffix}",
        body: "First collapsed review message",
        received_at: 2.minutes.ago
      )
      later = create_collapsed_review_message(
        sibling,
        connection:,
        customer_email:,
        provider_message_id: "collapsed-later-#{suffix}",
        body: "Later collapsed review message",
        received_at: 1.minute.ago
      )
      owner.update!(attention_required_at: first.received_at)
      sibling.update!(attention_required_at: later.received_at)
      [ owner, sibling, first, later ]
    end

    def create_collapsed_review_message(
      conversation,
      connection:,
      customer_email:,
      provider_message_id:,
      body:,
      received_at:
    )
      conversation.conversation_messages.create!(
        account: conversation.account,
        email_connection: connection,
        email_connection_generation: connection.credential_generation,
        provider_account_id: connection.provider_account_id,
        provider_message_id:,
        provider_thread_id: "collapsed-review-thread",
        internet_message_id: "<#{provider_message_id}@example.com>",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at:,
        from_address: customer_email,
        body:,
        matching_status: :unmatched,
        matching_method: :none,
        review_required: true,
        review_reasons: [ "invoice_unmatched" ]
      )
    end
end
