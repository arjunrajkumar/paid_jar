# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_22_160000) do
  create_table "account_external_id_sequences", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "value", default: 0, null: false
    t.index ["value"], name: "index_account_external_id_sequences_on_value", unique: true
  end

  create_table "accounts", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.boolean "automatic_invoice_reminders_enabled", default: false, null: false
    t.datetime "created_at", null: false
    t.bigint "external_account_id", null: false
    t.string "invoice_reminder_from_email"
    t.string "invoice_reminder_from_name"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["external_account_id"], name: "index_accounts_on_external_account_id", unique: true
    t.index ["name"], name: "index_accounts_on_name"
  end

  create_table "conversation_events", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "actor_kind", null: false
    t.bigint "actor_user_id"
    t.bigint "conversation_id", null: false
    t.bigint "conversation_message_id"
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.json "metadata", null: false
    t.index ["account_id", "kind", "created_at"], name: "index_conversation_events_on_account_kind_created_at"
    t.index ["actor_user_id"], name: "index_conversation_events_on_actor_user_id"
    t.index ["conversation_id", "created_at", "id"], name: "index_conversation_events_on_conversation_created_at_id"
    t.index ["conversation_message_id"], name: "index_conversation_events_on_conversation_message_id"
  end

  create_table "conversation_messages", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.boolean "automatic", default: false, null: false
    t.json "bcc_addresses", null: false
    t.text "body"
    t.json "cc_addresses", null: false
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "delivery_attempted_at"
    t.string "delivery_job_id", collation: "utf8mb4_0900_bin"
    t.string "direction", null: false
    t.bigint "email_connection_id"
    t.integer "email_connection_generation"
    t.text "failure_reason"
    t.string "from_address"
    t.json "in_reply_to_message_ids", null: false
    t.text "internet_message_id"
    t.string "internet_message_id_digest", limit: 64, collation: "utf8mb4_0900_bin"
    t.bigint "invoice_id"
    t.string "kind", null: false
    t.string "matching_method", default: "none", null: false
    t.string "matching_status", default: "matched", null: false
    t.string "provider_account_id", collation: "utf8mb4_0900_bin"
    t.string "provider_message_id", collation: "utf8mb4_0900_bin"
    t.json "provider_metadata", null: false
    t.string "provider_thread_id", collation: "utf8mb4_0900_bin"
    t.datetime "received_at"
    t.json "reference_message_ids", null: false
    t.json "reply_to_addresses", null: false
    t.json "review_reasons", null: false
    t.boolean "review_required", default: false, null: false
    t.datetime "reviewed_at"
    t.datetime "sent_at"
    t.string "status", default: "pending", null: false
    t.text "subject"
    t.json "to_addresses", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "provider_account_id", "internet_message_id_digest"], name: "index_conversation_messages_on_account_rfc_message"
    t.index ["account_id", "provider_account_id", "provider_message_id"], name: "index_conversation_messages_on_provider_message", unique: true
    t.index ["account_id", "provider_account_id", "provider_thread_id"], name: "index_conversation_messages_on_provider_thread"
    t.index ["account_id", "review_required", "reviewed_at", "received_at"], name: "index_conversation_messages_for_review"
    t.index ["account_id"], name: "index_conversation_messages_on_account_id"
    t.index ["conversation_id", "created_at", "id"], name: "index_conversation_messages_on_conversation_created_at_id"
    t.index ["delivery_job_id"], name: "index_conversation_messages_on_delivery_job_id"
    t.index ["email_connection_id"], name: "index_conversation_messages_on_email_connection_id"
    t.index ["invoice_id", "direction", "status", "sent_at"], name: "index_conversation_messages_on_outbound_delivery"
    t.index ["invoice_id"], name: "index_conversation_messages_on_invoice_id"
    t.index ["status", "delivery_attempted_at"], name: "index_conversation_messages_on_pending_delivery_age"
  end

  create_table "conversations", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.bigint "customer_id"
    t.bigint "invoice_id"
    t.datetime "resolved_at"
    t.string "status", default: "open", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "status", "updated_at"], name: "index_conversations_on_account_status_updated_at"
    t.index ["customer_id", "status", "updated_at"], name: "index_conversations_on_customer_status_updated_at"
    t.index ["invoice_id"], name: "index_conversations_on_invoice_id", unique: true
    t.check_constraint "((`status` = _utf8mb4'open') and (`resolved_at` is null)) or ((`status` = _utf8mb4'resolved') and (`resolved_at` is not null))", name: "conversations_status_and_resolved_at_consistent"
  end

  create_table "customer_email_addresses", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "customer_id", null: false
    t.string "email", null: false
    t.datetime "updated_at", null: false
    t.index ["customer_id", "email"], name: "index_customer_email_addresses_on_customer_id_and_email", unique: true
    t.index ["customer_id"], name: "index_customer_email_addresses_on_customer_id"
  end

  create_table "customer_segments", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.integer "on_time_rate"
    t.string "payer_segment", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "payer_segment"], name: "index_customer_segments_on_account_id_and_payer_segment", unique: true
    t.index ["account_id"], name: "index_customer_segments_on_account_id"
  end

  create_table "customers", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.bigint "customer_segment_id", null: false
    t.datetime "details_observed_at"
    t.string "email"
    t.string "external_id", null: false
    t.bigint "invoice_source_id", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "customer_segment_id"], name: "index_customers_on_account_id_and_customer_segment_id"
    t.index ["account_id", "name"], name: "index_customers_on_account_id_and_name"
    t.index ["customer_segment_id"], name: "index_customers_on_customer_segment_id"
    t.index ["invoice_source_id", "external_id"], name: "index_customers_on_invoice_source_id_and_external_id", unique: true
  end

  create_table "email_connections", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.text "access_token"
    t.bigint "account_id", null: false
    t.string "connected_email", null: false
    t.datetime "created_at", null: false
    t.integer "credential_generation", default: 0, null: false
    t.string "inbound_cursor", collation: "utf8mb4_0900_bin"
    t.datetime "inbound_enabled_at"
    t.datetime "inbound_sync_enqueued_at"
    t.string "inbound_sync_job_id", collation: "utf8mb4_0900_bin"
    t.text "last_error"
    t.datetime "last_inbound_attempted_at"
    t.text "last_inbound_error"
    t.datetime "last_inbound_synced_at"
    t.string "provider", null: false
    t.string "provider_account_id", collation: "utf8mb4_0900_bin"
    t.string "provider_display_name"
    t.text "refresh_token"
    t.json "scopes", null: false
    t.string "status", default: "pending", null: false
    t.datetime "token_expires_at"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_email_connections_on_account_id", unique: true
    t.index ["provider", "provider_account_id"], name: "index_email_connections_on_provider_account"
    t.index ["provider", "status"], name: "index_email_connections_on_provider_and_status"
  end

  create_table "email_message_receipts", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.integer "attempts", default: 0, null: false
    t.bigint "conversation_message_id"
    t.datetime "created_at", null: false
    t.string "direction"
    t.datetime "discovered_at", null: false
    t.bigint "email_connection_id", null: false
    t.integer "email_connection_generation", null: false
    t.text "last_error"
    t.json "metadata", null: false
    t.datetime "next_retry_at"
    t.datetime "processed_at"
    t.datetime "processing_enqueued_at"
    t.string "processing_enqueued_job_id", collation: "utf8mb4_0900_bin"
    t.string "processing_job_id", collation: "utf8mb4_0900_bin"
    t.datetime "processing_started_at"
    t.string "provider_account_id", null: false, collation: "utf8mb4_0900_bin"
    t.string "provider_history_id", collation: "utf8mb4_0900_bin"
    t.string "provider_message_id", null: false, collation: "utf8mb4_0900_bin"
    t.string "provider_thread_id", collation: "utf8mb4_0900_bin"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_message_id"], name: "index_email_message_receipts_on_conversation_message_id"
    t.index ["email_connection_id", "provider_account_id", "provider_message_id"], name: "index_email_receipts_on_connection_message", unique: true
    t.index ["status", "next_retry_at", "id"], name: "index_email_receipts_for_retry"
    t.index ["status", "processing_started_at"], name: "index_email_receipts_for_stale_processing"
  end

  create_table "external_identities", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address"
    t.bigint "identity_id", null: false
    t.string "provider", null: false
    t.string "subject", null: false, collation: "utf8mb4_0900_bin"
    t.datetime "updated_at", null: false
    t.index ["identity_id", "provider"], name: "index_external_identities_on_identity_id_and_provider", unique: true
    t.index ["identity_id"], name: "index_external_identities_on_identity_id"
    t.index ["provider", "subject"], name: "index_external_identities_on_provider_and_subject", unique: true
  end

  create_table "identities", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_identities_on_email_address", unique: true
  end

  create_table "invoice_reminder_suppressions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "category", null: false
    t.datetime "created_at", null: false
    t.integer "day_offset", null: false
    t.bigint "invoice_id", null: false
    t.bigint "invoice_schedule_id"
    t.string "reason", null: false
    t.string "stage_key", null: false
    t.datetime "suppressed_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_invoice_reminder_suppressions_on_account_id"
    t.index ["invoice_id", "invoice_schedule_id"], name: "index_reminder_suppressions_on_invoice_and_schedule", unique: true
    t.index ["invoice_id", "stage_key"], name: "index_reminder_suppressions_on_invoice_and_stage", unique: true
    t.index ["invoice_id"], name: "index_invoice_reminder_suppressions_on_invoice_id"
    t.index ["invoice_schedule_id"], name: "index_invoice_reminder_suppressions_on_invoice_schedule_id"
    t.check_constraint "`day_offset` > 0", name: "invoice_reminder_suppressions_day_offset_positive"
  end

  create_table "invoice_reminders", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "category", null: false
    t.bigint "conversation_message_id", null: false
    t.datetime "created_at", null: false
    t.integer "day_offset", null: false
    t.bigint "invoice_id", null: false
    t.bigint "invoice_schedule_id"
    t.string "stage_key", null: false
    t.string "tone"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_invoice_reminders_on_account_id"
    t.index ["conversation_message_id"], name: "index_invoice_reminders_on_conversation_message_id", unique: true
    t.index ["invoice_id", "invoice_schedule_id"], name: "index_invoice_reminders_on_invoice_and_schedule", unique: true
    t.index ["invoice_id", "stage_key"], name: "index_invoice_reminders_on_invoice_id_and_stage_key", unique: true
    t.index ["invoice_id"], name: "index_invoice_reminders_on_invoice_id"
    t.index ["invoice_schedule_id"], name: "index_invoice_reminders_on_invoice_schedule_id"
  end

  create_table "invoice_schedules", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "category", null: false
    t.datetime "created_at", null: false
    t.integer "day_offset", null: false
    t.string "kind", null: false
    t.string "tone", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "kind", "category", "day_offset"], name: "index_invoice_schedules_on_account_and_stage", unique: true
    t.index ["account_id"], name: "index_invoice_schedules_on_account_id"
    t.check_constraint "`day_offset` > 0", name: "invoice_schedules_day_offset_positive"
  end

  create_table "invoice_source_webhook_events", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.bigint "invoice_source_id", null: false
    t.text "last_error"
    t.datetime "occurred_at"
    t.json "payload", null: false
    t.datetime "processed_at"
    t.string "provider", null: false
    t.string "provider_event_id", null: false
    t.string "resource_id"
    t.string "resource_type"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["invoice_source_id", "provider_event_id"], name: "idx_on_invoice_source_id_provider_event_id_2b2653d813", unique: true
    t.index ["invoice_source_id", "status"], name: "idx_on_invoice_source_id_status_f801f9a661"
    t.index ["invoice_source_id"], name: "index_invoice_source_webhook_events_on_invoice_source_id"
    t.index ["occurred_at"], name: "index_invoice_source_webhook_events_on_occurred_at"
  end

  create_table "invoice_sources", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.text "access_token"
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "external_account_id", null: false
    t.string "external_account_name"
    t.text "last_error"
    t.datetime "last_synced_at"
    t.string "provider", null: false
    t.json "provider_data", null: false
    t.json "raw_token_data", null: false
    t.text "refresh_token"
    t.json "scopes", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "provider"], name: "index_invoice_sources_on_account_id_and_provider", unique: true
    t.index ["account_id"], name: "index_invoice_sources_on_account_id"
    t.index ["provider", "external_account_id"], name: "index_invoice_sources_on_provider_and_external_account_id", unique: true
    t.index ["provider", "status"], name: "index_invoice_sources_on_provider_and_status"
  end

  create_table "invoices", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.decimal "amount_due", precision: 12, scale: 2
    t.decimal "amount_paid", precision: 12, scale: 2
    t.date "completed_on"
    t.string "contact_external_id"
    t.string "contact_name"
    t.datetime "created_at", null: false
    t.string "currency"
    t.bigint "customer_id", null: false
    t.date "due_on"
    t.string "external_id", null: false
    t.bigint "invoice_source_id", null: false
    t.string "invoice_type"
    t.date "issued_on"
    t.string "number"
    t.date "paid_on"
    t.json "provider_data", null: false
    t.string "provider_status"
    t.json "raw_data", null: false
    t.string "status", default: "unknown", null: false
    t.datetime "synced_at"
    t.decimal "total", precision: 12, scale: 2
    t.datetime "updated_at", null: false
    t.index ["account_id", "status"], name: "index_invoices_on_account_id_and_status"
    t.index ["account_id"], name: "index_invoices_on_account_id"
    t.index ["customer_id", "completed_on"], name: "index_invoices_on_customer_id_and_completed_on"
    t.index ["customer_id"], name: "index_invoices_on_customer_id"
    t.index ["due_on"], name: "index_invoices_on_due_on"
    t.index ["invoice_source_id", "external_id"], name: "index_invoices_on_invoice_source_id_and_external_id", unique: true
    t.index ["invoice_source_id"], name: "index_invoices_on_invoice_source_id"
    t.index ["paid_on"], name: "index_invoices_on_paid_on"
  end

  create_table "magic_links", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "identity_id", null: false
    t.integer "purpose", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_magic_links_on_code", unique: true
    t.index ["expires_at"], name: "index_magic_links_on_expires_at"
    t.index ["identity_id"], name: "index_magic_links_on_identity_id"
  end

  create_table "notification_subscriptions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "email", default: false, null: false
    t.string "event", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "event"], name: "index_notification_subscriptions_on_user_id_and_event", unique: true
    t.index ["user_id"], name: "index_notification_subscriptions_on_user_id"
  end

  create_table "payment_promises", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "active_invoice_id"
    t.datetime "created_at", null: false
    t.bigint "follow_up_message_id"
    t.date "follow_up_on", null: false
    t.bigint "invoice_id", null: false
    t.date "promised_on", null: false
    t.bigint "source_message_id", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_payment_promises_on_account_id"
    t.index ["active_invoice_id"], name: "index_payment_promises_on_active_invoice_id", unique: true
    t.index ["follow_up_message_id"], name: "index_payment_promises_on_follow_up_message_id", unique: true
    t.index ["invoice_id", "status", "follow_up_on"], name: "index_payment_promises_on_invoice_status_and_follow_up"
    t.index ["invoice_id"], name: "index_payment_promises_on_invoice_id"
    t.index ["source_message_id"], name: "index_payment_promises_on_source_message_id", unique: true
    t.index ["status", "follow_up_on"], name: "index_payment_promises_on_due_follow_up"
    t.check_constraint "((`status` = _utf8mb4'active') and (`active_invoice_id` is not null) and (`active_invoice_id` = `invoice_id`)) or ((`status` <> _utf8mb4'active') and (`active_invoice_id` is null))", name: "payment_promises_active_invoice_matches_status"
  end

  create_table "platform_admin_events", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id"
    t.string "action", null: false
    t.string "actor_email_address", null: false
    t.bigint "actor_identity_id"
    t.datetime "created_at", null: false
    t.json "metadata", null: false
    t.bigint "target_id"
    t.string "target_type"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_platform_admin_events_on_account_id"
    t.index ["action", "created_at"], name: "index_platform_admin_events_on_action_and_created_at"
    t.index ["actor_identity_id"], name: "index_platform_admin_events_on_actor_identity_id"
    t.index ["target_type", "target_id"], name: "index_platform_admin_events_on_target_type_and_target_id"
  end

  create_table "sessions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "identity_id", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.index ["identity_id"], name: "index_sessions_on_identity_id"
  end

  create_table "stripe_installation_claims", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id"
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.boolean "livemode", null: false
    t.string "request_digest", limit: 64, null: false
    t.string "stripe_account_id", null: false
    t.string "stripe_user_id", null: false
    t.string "token_digest", limit: 64, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_stripe_installation_claims_on_account_id"
    t.index ["expires_at"], name: "index_stripe_installation_claims_on_expires_at"
    t.index ["request_digest"], name: "index_stripe_installation_claims_on_request_digest", unique: true
    t.index ["stripe_account_id", "livemode"], name: "idx_on_stripe_account_id_livemode_2fff42ae45"
    t.index ["token_digest"], name: "index_stripe_installation_claims_on_token_digest", unique: true
  end

  create_table "users", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.bigint "identity_id"
    t.string "name", null: false
    t.string "role", default: "member", null: false
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.index ["account_id", "identity_id"], name: "index_users_on_account_id_and_identity_id", unique: true
    t.index ["account_id", "role"], name: "index_users_on_account_id_and_role"
    t.index ["account_id"], name: "index_users_on_account_id"
    t.index ["identity_id"], name: "index_users_on_identity_id"
  end

  add_foreign_key "conversation_events", "accounts"
  add_foreign_key "conversation_events", "conversation_messages", on_delete: :nullify
  add_foreign_key "conversation_events", "conversations"
  add_foreign_key "conversation_events", "users", column: "actor_user_id", on_delete: :nullify
  add_foreign_key "conversation_messages", "accounts"
  add_foreign_key "conversation_messages", "conversations"
  add_foreign_key "conversation_messages", "email_connections", on_delete: :nullify
  add_foreign_key "conversation_messages", "invoices"
  add_foreign_key "conversations", "accounts"
  add_foreign_key "conversations", "customers", on_delete: :nullify
  add_foreign_key "conversations", "invoices"
  add_foreign_key "customer_email_addresses", "customers", on_delete: :cascade
  add_foreign_key "customer_segments", "accounts"
  add_foreign_key "customers", "accounts"
  add_foreign_key "customers", "customer_segments"
  add_foreign_key "customers", "invoice_sources"
  add_foreign_key "email_connections", "accounts"
  add_foreign_key "email_message_receipts", "accounts"
  add_foreign_key "email_message_receipts", "conversation_messages", on_delete: :nullify
  add_foreign_key "email_message_receipts", "email_connections"
  add_foreign_key "external_identities", "identities", on_delete: :cascade
  add_foreign_key "invoice_reminder_suppressions", "accounts"
  add_foreign_key "invoice_reminder_suppressions", "invoice_schedules", on_delete: :nullify
  add_foreign_key "invoice_reminder_suppressions", "invoices"
  add_foreign_key "invoice_reminders", "accounts"
  add_foreign_key "invoice_reminders", "conversation_messages"
  add_foreign_key "invoice_reminders", "invoice_schedules", on_delete: :nullify
  add_foreign_key "invoice_reminders", "invoices"
  add_foreign_key "invoice_schedules", "accounts"
  add_foreign_key "invoice_source_webhook_events", "invoice_sources"
  add_foreign_key "invoice_sources", "accounts"
  add_foreign_key "invoices", "accounts"
  add_foreign_key "invoices", "customers"
  add_foreign_key "invoices", "invoice_sources"
  add_foreign_key "magic_links", "identities"
  add_foreign_key "notification_subscriptions", "users", on_delete: :cascade
  add_foreign_key "payment_promises", "accounts"
  add_foreign_key "payment_promises", "conversation_messages", column: "follow_up_message_id"
  add_foreign_key "payment_promises", "conversation_messages", column: "source_message_id"
  add_foreign_key "payment_promises", "invoices"
  add_foreign_key "payment_promises", "invoices", column: "active_invoice_id"
  add_foreign_key "platform_admin_events", "accounts", on_delete: :nullify
  add_foreign_key "platform_admin_events", "identities", column: "actor_identity_id", on_delete: :nullify
  add_foreign_key "sessions", "identities"
  add_foreign_key "stripe_installation_claims", "accounts", on_delete: :nullify
  add_foreign_key "users", "accounts"
  add_foreign_key "users", "identities"
end
