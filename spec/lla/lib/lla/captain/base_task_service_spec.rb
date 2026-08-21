# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::Captain::BaseTaskService, type: :service do
  let(:account) { create(:account, limits: { captain_responses: 1 }) }
  let(:conversation) { create(:conversation, account: account) }
  let(:perform_result) { { message: 'safe response' } }
  let(:calls) { [] }
  let(:service_class) do
    response = perform_result
    call_log = calls
    Class.new(Captain::BaseTaskService) do
      define_method(:perform) do
        call_log << :perform
        response
      end
      define_method(:event_name) { 'editor' }
    end
  end
  let(:service) do
    service_class.new(account: account, conversation_display_id: conversation.display_id)
                 .with_quota_idempotency_key('request-1', owner_token: 'worker-1')
  end

  before do
    account.enable_features!('captain_tasks')
    InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_OPEN_AI_API_KEY').update!(value: 'test-key')
    allow(Integrations::Openai::KeyValidator).to receive(:valid?).and_return(true)
  end

  it 'is the only quota wrapper in the concrete service ancestor chain' do
    quota_ancestor_names = service_class.ancestors.filter_map(&:name).grep(/Captain::BaseTaskService\z/)

    expect(quota_ancestor_names).to include(described_class.name)
    expect(quota_ancestor_names).not_to include('Enterprise::Captain::BaseTaskService')
    expect(service.method(:perform).source_location.first).to start_with(Rails.root.join('lla/rails').to_s)
  end

  it 'consumes a reservation only after an effective result' do
    expect(service.perform).to eq(perform_result)

    expect(account.lla_captain_quota_ledgers.sole).to have_attributes(reserved_units: 0, consumed_units: 1)
  end

  it 'fails before calling the task when quota is exhausted' do
    first = Lla::Captain::QuotaManager.new(
      account: account, idempotency_key: 'first', owner_token: 'worker', feature: 'editor', provider: 'openai',
      credential_source: 'system', reason: 'spec'
    )
    first.reserve!
    first.consume!

    result = service.perform

    expect(result).to include(error_code: 429, code: 'lla_quota_exhausted')
    expect(calls).to be_empty
  end

  context 'when the effective task result fails' do
    let(:perform_result) { { error: 'provider unavailable' } }

    it 'releases the reservation' do
      expect(service.perform).to eq(perform_result)

      expect(account.lla_captain_quota_ledgers.sole).to have_attributes(reserved_units: 0, consumed_units: 0, released_units: 1)
    end
  end

  context 'when the task uses an account-owned API key' do
    let(:service_class) do
      response = perform_result
      call_log = calls
      Class.new(Captain::BaseTaskService) do
        define_method(:perform) do
          call_log << :perform
          response
        end
        define_method(:event_name) { 'editor' }
        define_method(:use_account_openai_hook?) { true }
      end
    end

    before { create(:integrations_hook, :openai, account: account, settings: { 'api_key' => 'customer-key' }) }

    it 'executes without debiting the LLA system quota' do
      expect(service.perform).to eq(perform_result)
      expect(account.lla_captain_quota_ledgers).to be_empty
    end
  end
end
