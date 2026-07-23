class Conversations::ReviewWorkUnit
  class << self
    def message_scope_for(message:)
      key = review_key(message)
      return message.account.conversation_messages.where(id: message.id) unless key

      owner = review_owner_for(message:, key:)
      allowed_ids = owner.conversation_group_ids + unlinked_review_conversation_ids(
        account: message.account,
        keys: [ key ]
      )
      thread_scope(account: message.account, keys: [ key ])
        .where(conversation_id: allowed_ids.uniq)
    end

    def message_scope_for_conversation(conversation:)
      conversation = conversation.canonical
      account = conversation.account
      base_ids = conversation.conversation_group_ids
      base = account.conversation_messages.where(conversation_id: base_ids)

      keys = review_keys(
        account.conversation_messages.where(conversation_id: base_ids)
      )
      return base if keys.empty?

      sibling_ids = thread_scope(account:, keys:)
        .where(
          conversation_id: unlinked_review_conversation_ids(account:, keys:)
        )
        .pluck(:id)
      base.or(account.conversation_messages.where(id: sibling_ids))
    end

    def conversation_ids_for(conversation:)
      message_scope_for_conversation(conversation:)
        .distinct
        .pluck(:conversation_id)
    end

    def includes_message?(conversation:, message:)
      return false unless conversation.account_id == message.account_id

      message_scope_for_conversation(conversation:).where(id: message.id).exists?
    end

    def source_conversation_ids_for(message:)
      scope = message_scope_for(message:)
      message.account.conversations
        .where(id: scope.distinct.pluck(:conversation_id), invoice_id: nil)
        .pluck(:id)
        .then { |ids| (ids + [ message.conversation_id ]).uniq.sort }
    end

    def expand_root_mapping(account:, root_by_conversation_id:)
      root_ids = root_by_conversation_id.values.uniq
      invoice_id_by_root = account.conversations
        .where(id: root_ids)
        .pluck(:id, :invoice_id)
        .to_h
      rows = account.conversation_messages
        .where(
          conversation_id: root_by_conversation_id.keys,
          review_required: true
        )
        .where.not(provider_account_id: nil, provider_thread_id: nil)
        .pluck(:conversation_id, :provider_account_id, :provider_thread_id)
      root_by_key = rows.each_with_object({}) do |row, result|
        conversation_id, provider_account_id, provider_thread_id = row
        root_id = root_by_conversation_id.fetch(conversation_id)
        key = [ provider_account_id, provider_thread_id ]
        result[key] = preferred_root_id(
          result[key],
          root_id,
          invoice_id_by_root:
        )
      end
      return root_by_conversation_id if root_by_key.empty?

      thread_scope(account:, keys: root_by_key.keys)
        .joins(:conversation)
        .where(
          review_required: true,
          conversations: {
            invoice_id: nil,
            canonical_conversation_id: nil
          }
        )
        .pluck(
          :conversation_id,
          :provider_account_id,
          :provider_thread_id
        )
        .each do |conversation_id, provider_account_id, provider_thread_id|
          root_id = root_by_key[[ provider_account_id, provider_thread_id ]]
          root_by_conversation_id[conversation_id] ||= root_id if root_id
        end
      root_by_conversation_id
    end

    def group_membership_sql(message_alias:, conversation_alias:)
      <<~SQL.squish
        #{message_alias}.conversation_id = #{conversation_alias}.id
        OR #{message_alias}.conversation_id IN (
          SELECT linked_conversations.id
          FROM conversations AS linked_conversations
          WHERE linked_conversations.canonical_conversation_id = #{conversation_alias}.id
        )
        OR #{message_alias}.id IN (
          SELECT review_sibling.id
          FROM conversation_messages AS review_owner
          INNER JOIN conversation_messages AS review_sibling
            ON review_sibling.account_id = review_owner.account_id
            AND review_sibling.provider_account_id = review_owner.provider_account_id
            AND review_sibling.provider_thread_id = review_owner.provider_thread_id
          INNER JOIN conversations AS review_sibling_conversation
            ON review_sibling_conversation.id = review_sibling.conversation_id
          WHERE (
              review_owner.conversation_id = #{conversation_alias}.id
              OR review_owner.conversation_id IN (
                SELECT linked_review_owner.id
                FROM conversations AS linked_review_owner
                WHERE linked_review_owner.canonical_conversation_id =
                  #{conversation_alias}.id
              )
            )
            AND review_owner.email_connection_id IS NOT NULL
            AND review_owner.review_required = TRUE
            AND review_owner.provider_account_id IS NOT NULL
            AND review_owner.provider_thread_id IS NOT NULL
            AND review_sibling.email_connection_id IS NOT NULL
            AND review_sibling_conversation.invoice_id IS NULL
        )
      SQL
    end

    def visible_owner_sql(conversation_alias:)
      <<~SQL.squish
        NOT (
          #{conversation_alias}.invoice_id IS NULL
          AND EXISTS (
            SELECT 1
            FROM conversation_messages AS current_review
            WHERE current_review.conversation_id = #{conversation_alias}.id
              AND current_review.email_connection_id IS NOT NULL
              AND current_review.review_required = TRUE
              AND current_review.provider_account_id IS NOT NULL
              AND current_review.provider_thread_id IS NOT NULL
          )
          AND NOT EXISTS (
            SELECT 1
            FROM conversation_messages AS non_review_message
            WHERE non_review_message.conversation_id = #{conversation_alias}.id
              AND NOT EXISTS (
                SELECT 1
                FROM conversation_messages AS owning_review
                WHERE owning_review.conversation_id = #{conversation_alias}.id
                  AND owning_review.email_connection_id IS NOT NULL
                  AND owning_review.review_required = TRUE
                  AND owning_review.provider_account_id = non_review_message.provider_account_id
                  AND owning_review.provider_thread_id = non_review_message.provider_thread_id
              )
          )
          AND EXISTS (
            SELECT 1
            FROM conversation_messages AS current_review
            INNER JOIN conversation_messages AS earlier_review
              ON earlier_review.account_id = current_review.account_id
              AND earlier_review.provider_account_id = current_review.provider_account_id
              AND earlier_review.provider_thread_id = current_review.provider_thread_id
            INNER JOIN conversations AS earlier_review_conversation
              ON earlier_review_conversation.id = earlier_review.conversation_id
            INNER JOIN conversations AS earlier_review_root
              ON earlier_review_root.id = COALESCE(
                earlier_review_conversation.canonical_conversation_id,
                earlier_review_conversation.id
              )
            WHERE current_review.conversation_id = #{conversation_alias}.id
              AND current_review.email_connection_id IS NOT NULL
              AND current_review.review_required = TRUE
              AND current_review.provider_account_id IS NOT NULL
              AND current_review.provider_thread_id IS NOT NULL
              AND earlier_review.email_connection_id IS NOT NULL
              AND earlier_review.review_required = TRUE
              AND (
                earlier_review_root.invoice_id IS NOT NULL
                OR (
                  earlier_review_root.invoice_id IS NULL
                  AND earlier_review_root.id < #{conversation_alias}.id
                )
              )
          )
        )
      SQL
    end

    private
      def review_key(message)
        return unless message.review_required?
        return if message.provider_account_id.blank? || message.provider_thread_id.blank?

        [ message.provider_account_id, message.provider_thread_id ]
      end

      def review_keys(scope)
        scope.where(review_required: true)
          .where.not(provider_account_id: nil, provider_thread_id: nil)
          .distinct
          .pluck(:provider_account_id, :provider_thread_id)
      end

      def review_owner_for(message:, key:)
        root = message.conversation.canonical
        return root if root.invoice_id.present?

        invoice_conversation_id = thread_scope(
          account: message.account,
          keys: [ key ]
        )
          .joins(:conversation)
          .where(
            review_required: true,
            conversations: { canonical_conversation_id: nil }
          )
          .where.not(conversations: { invoice_id: nil })
          .minimum(:conversation_id)
        invoice_conversation_id ?
          message.account.conversations.find(invoice_conversation_id) :
          root
      end

      def unlinked_review_conversation_ids(account:, keys:)
        thread_scope(account:, keys:)
          .joins(:conversation)
          .where(
            review_required: true,
            conversations: {
              invoice_id: nil,
              canonical_conversation_id: nil
            }
          )
          .distinct
          .pluck(:conversation_id)
      end

      def preferred_root_id(existing_root_id, candidate_root_id, invoice_id_by_root:)
        return candidate_root_id unless existing_root_id

        [ existing_root_id, candidate_root_id ].min_by do |root_id|
          [ invoice_id_by_root[root_id] ? 0 : 1, root_id ]
        end
      end

      def thread_scope(account:, keys:)
        account.conversation_messages.where(key_condition(keys))
      end

      def key_condition(keys)
        table = ConversationMessage.arel_table
        keys.map do |provider_account_id, provider_thread_id|
          table[:provider_account_id].eq(provider_account_id).and(
            table[:provider_thread_id].eq(provider_thread_id)
          )
        end.reduce(&:or)
      end
  end
end
