# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::CustomDomains::OperationService do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:domain) { Lla::CustomDomains::LifecycleService.new(portal: portal).request!('docs.example.com') }

  describe '.enqueue!' do
    it 'collapses concurrent duplicate requests into one operation' do
      first = described_class.enqueue!(domain: domain, operation_type: 'provision')
      second = described_class.enqueue!(domain: domain, operation_type: 'provision')

      expect(second.id).to eq(first.id)
      expect(Lla::CustomDomains::Operation.where(operation_type: 'provision').count).to eq(1)
    end

    it 'creates a distinct operation once the domain version moves' do
      first = described_class.enqueue!(domain: domain, operation_type: 'provision')
      domain.update!(version: domain.version + 1)
      second = described_class.enqueue!(domain: domain, operation_type: 'provision')

      expect(second.id).not_to eq(first.id)
      expect(second.domain_version).to eq(domain.version)
    end

    it 'rejects an unknown operation type' do
      expect { described_class.enqueue!(domain: domain, operation_type: 'drop_database') }
        .to raise_error(ArgumentError)
    end
  end

  describe '.enqueue_teardown!' do
    it 'never schedules provider work when there is no remote resource' do
      expect(
        described_class.enqueue_teardown!(account_id: account.id, hostname: 'docs.example.com',
                                          provider: 'none', provider_resource_id: nil, domain_version: 1)
      ).to be_nil
      expect(Lla::CustomDomains::Operation.count).to eq(0)
    end

    it 'is idempotent for the same remote resource' do
      2.times do
        described_class.enqueue_teardown!(account_id: account.id, hostname: 'docs.example.com',
                                          provider: 'cloudflare', provider_resource_id: 'cf-1', domain_version: 1)
      end

      expect(Lla::CustomDomains::Operation.where(operation_type: 'remove').count).to eq(1)
    end
  end

  describe '.claim!' do
    it 'lets exactly one worker claim an operation' do
      operation = described_class.enqueue!(domain: domain, operation_type: 'provision')

      expect(described_class.claim!(operation)).to be_present
      expect(described_class.claim!(Lla::CustomDomains::Operation.find(operation.id))).to be_nil
    end

    it 'does not claim before the backoff window' do
      operation = described_class.enqueue!(domain: domain, operation_type: 'provision')
      operation.update!(available_at: 5.minutes.from_now)

      expect(described_class.claim!(operation)).to be_nil
    end
  end

  describe '.fail!' do
    it 'backs off then dead letters once the budget is spent' do
      operation = described_class.enqueue!(domain: domain, operation_type: 'provision')

      described_class.fail!(described_class.claim!(operation), code: 'lla_custom_domain_provider_timeout')
      expect(operation.reload).to have_attributes(state: 'pending', attempts: 1)
      expect(operation.available_at).to be > Time.current

      (operation.max_attempts - 1).times do
        operation.update!(available_at: 1.minute.ago)
        described_class.fail!(described_class.claim!(operation), code: 'lla_custom_domain_provider_timeout')
      end

      expect(operation.reload).to have_attributes(state: 'dead_lettered',
                                                  attempts: operation.max_attempts,
                                                  last_error_code: 'lla_custom_domain_provider_timeout')
    end
  end
end
