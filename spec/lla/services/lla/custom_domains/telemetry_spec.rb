# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::CustomDomains::Telemetry do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:lifecycle) { Lla::CustomDomains::LifecycleService.new(portal: portal) }
  let(:service) { Lla::CustomDomains::OperationService }

  def captured_events
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(/\A#{described_class::NAMESPACE}\./o) do |name, _s, _f, _id, payload|
      events << [name, payload]
    end
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  describe 'redaction' do
    it 'drops every label that is not on the allow-list' do
      payload = described_class.emit('lifecycle_transition', account_id: 7, state: 'active',
                                                             hostname: 'docs.example.com',
                                                             challenge_body: 'proof-body',
                                                             api_token: 'token-value-1234567890',
                                                             provider_body: '{"secret":1}')

      expect(payload.keys).to contain_exactly(:event, :account_id, :state)
      expect(payload.values.map(&:to_s).join(' ')).not_to include('docs.example.com', 'proof-body', 'token-value')
    end

    it 'drops allow-listed labels whose value is not a safe code' do
      payload = described_class.emit('lifecycle_transition', error_code: 'boom: https://evil.example.com/x',
                                                             state: 'active')

      expect(payload).not_to have_key(:error_code)
      expect(payload[:state]).to eq('active')
    end

    it 'never writes a hostname or token into the log line' do
      allow(Rails.logger).to receive(:info)
      domain = lifecycle.request!('docs.example.com')

      expect(Rails.logger).not_to have_received(:info).with(/docs\.example\.com/)
      expect(domain.state).to eq('ownership_pending')
    end
  end

  describe 'lifecycle coverage' do
    it 'emits a transition for every state change with internal identifiers only' do
      events = captured_events { lifecycle.request!('docs.example.com') }

      transition = events.find { |name, _| name.end_with?('lifecycle_transition') }
      expect(transition).to be_present
      expect(transition.last).to include(event: 'lifecycle_transition', state: 'ownership_pending',
                                         previous_state: 'requested')
      expect(transition.last).not_to have_key(:hostname)
    end

    it 'emits claim and terminal operation events exactly once per compare-and-set' do
      domain = lifecycle.request!('docs.example.com')
      operation = Lla::CustomDomains::Operation.find_by!(custom_domain_id: domain.id, operation_type: 'verify')

      events = captured_events do
        lease = service.claim!(operation)
        service.succeed!(lease)
        expect { service.succeed!(lease) }.to raise_error(service::LeaseLost)
      end

      names = events.map(&:first)
      expect(names.count { |name| name.end_with?('operation_claimed') }).to eq(1)
      expect(names.count { |name| name.end_with?('operation_succeeded') }).to eq(1)
    end

    it 'does not double count a recovery successor when two reconcilers race' do
      domain = lifecycle.request!('docs.example.com')
      operation = Lla::CustomDomains::Operation.find_by!(custom_domain_id: domain.id, operation_type: 'verify')
      operation.update_columns(state: 'cancelled', completed_at: Time.current, # rubocop:disable Rails/SkipsModelValidations
                               claim_digest: nil, claimed_at: nil)

      events = captured_events do
        2.times { Lla::CustomDomains::ReconciliationJob.perform_now }
      end

      recovery = events.map(&:first).count { |name| name.end_with?('operation_recovery_enqueued') }
      expect(recovery).to eq(1)
    end

    it 'emits a manual-intervention alert and health gauges for stuck state' do
      domain = lifecycle.request!('docs.example.com')
      lifecycle.fail!(domain, code: 'lla_custom_domain_ownership_unverified')

      events = captured_events { Lla::CustomDomains::ReconciliationJob.perform_now }

      gauges = events.select { |name, _| name.include?('health_') }
      expect(gauges.map(&:first)).to include("#{described_class::NAMESPACE}.health_failed_domains")
      expect(gauges.first.last).to have_key(:count)
    end
  end
end
