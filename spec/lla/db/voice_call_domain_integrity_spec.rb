require 'rails_helper'

RSpec.describe 'LLA voice call database integrity', type: :model do
  let(:connection) { ActiveRecord::Base.connection }
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:call) do
    create(:call, account: account, inbox: conversation.inbox, conversation: conversation,
                  contact: conversation.contact)
  end

  it 'has tenant-scoped provider identity and query indexes' do
    indexes = connection.indexes(:calls).index_by(&:name)

    expect(indexes.fetch('idx_lla_calls_provider_identity')).to have_attributes(
      columns: %w[account_id inbox_id provider provider_call_id],
      unique: true
    )
    expect(indexes).to include('idx_lla_calls_account_status_created', 'idx_lla_calls_inbox_active')
    expect(indexes).not_to include('index_calls_on_provider_and_provider_call_id')
  end

  it 'enforces composite tenant foreign keys below the model layer' do
    other_account = create(:account)

    expect do
      connection.transaction(requires_new: true) do
        connection.execute("UPDATE calls SET account_id = #{other_account.id} WHERE id = #{call.id}")
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it 'rejects invalid call states below the model layer' do
    expect do
      connection.transaction(requires_new: true) do
        connection.execute("UPDATE calls SET status = 'rewinding' WHERE id = #{call.id}")
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /chk_lla_calls_status/)
  end

  it 'uses digest-only event ledger and operation outbox tables' do
    event_columns = connection.columns(:lla_call_events).index_by(&:name)
    operation_columns = connection.columns(:lla_call_operations).index_by(&:name)

    aggregate_failures do
      expect(event_columns).to include('event_id_digest', 'payload_digest', 'verified_at')
      expect(event_columns).not_to include('payload', 'raw_payload')
      expect(operation_columns).to include('idempotency_digest', 'request_digest', 'claim_digest', 'available_at')
      expect(operation_columns).not_to include('request_payload', 'response_payload')
    end
  end

  it 'has idempotency, digest-shape and bounded-attempt constraints' do
    event_indexes = connection.indexes(:lla_call_events).index_by(&:name)
    operation_indexes = connection.indexes(:lla_call_operations).index_by(&:name)
    event_checks = connection.check_constraints(:lla_call_events).index_by(&:name)
    operation_checks = connection.check_constraints(:lla_call_operations).index_by(&:name)

    aggregate_failures do
      expect(event_indexes.fetch('idx_lla_call_events_idempotency')).to have_attributes(unique: true)
      expect(operation_indexes.fetch('idx_lla_call_operations_idempotency')).to have_attributes(unique: true)
      expect(event_checks).to include('chk_lla_call_events_digests', 'chk_lla_call_events_outcome')
      expect(operation_checks).to include('chk_lla_call_operations_digests', 'chk_lla_call_operations_attempts')
    end
  end
end
