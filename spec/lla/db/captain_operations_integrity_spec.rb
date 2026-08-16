require 'rails_helper'

RSpec.describe 'LLA Captain operations database integrity', type: :model do
  let(:connection) { ActiveRecord::Base.connection }

  it 'has the effective feedback and retention indexes' do
    report_indexes = connection.indexes(:captain_message_reports).index_by(&:name)

    expect(report_indexes.fetch('idx_lla_message_reports_effective')).to have_attributes(
      columns: %w[account_id user_id message_id],
      unique: true
    )
    expect(report_indexes.fetch('idx_lla_message_reports_expiry').columns).to eq(['expires_at'])
  end

  it 'has composite tenant foreign keys for message feedback' do
    foreign_keys = connection.foreign_keys(:captain_message_reports).index_by(&:name)

    aggregate_failures do
      expect(foreign_keys).to include(
        'fk_lla_message_reports_message_tenant',
        'fk_lla_message_reports_conversation_tenant',
        'fk_lla_message_reports_membership'
      )
      expect(foreign_keys.fetch('fk_lla_message_reports_message_tenant').options).to include(
        column: %w[account_id message_id conversation_id],
        primary_key: %w[account_id id conversation_id]
      )
    end
  end

  it 'has allowlist and bounded-description checks for message feedback' do
    checks = connection.check_constraints(:captain_message_reports).index_by(&:name)

    expect(checks).to include('chk_lla_message_reports_reason', 'chk_lla_message_reports_description')
    expect(checks.fetch('chk_lla_message_reports_description').expression).to include('char_length', '500')
  end

  it 'stores only digests for bulk idempotency with a unique tenant key' do
    columns = connection.columns(:lla_captain_bulk_operations).index_by(&:name)
    index = connection.indexes(:lla_captain_bulk_operations)
                      .find { |candidate| candidate.name == 'idx_lla_bulk_operations_idempotency' }

    aggregate_failures do
      expect(columns).to include('key_digest', 'request_digest', 'expires_at')
      expect(columns).not_to include('operation_id')
      expect(index).to have_attributes(columns: %w[account_id key_digest], unique: true)
    end
  end

  it 'enforces digest shape, bounded batches and internally consistent counts' do
    checks = connection.check_constraints(:lla_captain_bulk_operations).index_by(&:name)

    expect(checks).to include(
      'chk_lla_bulk_operations_state',
      'chk_lla_bulk_operations_digests',
      'chk_lla_bulk_operations_counts'
    )
    expect(checks.fetch('chk_lla_bulk_operations_counts').expression).to include('requested_count', '100')
  end

  it 'has durable sync claim columns on Captain documents' do
    columns = connection.columns(:captain_documents).index_by(&:name)

    expect(columns).to include('sync_claim_digest', 'sync_claimed_at')
  end
end
