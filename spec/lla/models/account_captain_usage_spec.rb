# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Account, type: :model do
  describe 'LLA Captain quotas' do
    let(:account) do
      create(
        :account,
        limits: { captain_documents: 2, captain_responses: 1 },
        custom_attributes: { 'plan_name' => 'business', 'unrelated' => 'preserved' }
      )
    end

    it 'consumes a response atomically without replacing unrelated attributes' do
      expect(account.increment_response_usage).to be true
      expect(account.increment_response_usage).to be false

      expect(account.reload.custom_attributes).to include(
        'captain_responses_usage' => 1,
        'unrelated' => 'preserved'
      )
      expect(account.usage_limits.dig(:captain, :responses, :current_available)).to eq(0)
    end

    it 'recovers a malformed stored counter without exceeding the configured limit' do
      account.update!(custom_attributes: account.custom_attributes.merge('captain_responses_usage' => 'invalid'))

      expect(account.increment_response_usage).to be true
      expect(account.reload.custom_attributes['captain_responses_usage']).to eq(1)
    end

    it 'releases a reserved response exactly once without going negative' do
      account.update!(custom_attributes: account.custom_attributes.merge('captain_responses_usage' => 1))

      expect(account.decrement_response_usage).to be true
      expect(account.decrement_response_usage).to be false

      expect(account.reload.custom_attributes).to include(
        'captain_responses_usage' => 0,
        'unrelated' => 'preserved'
      )
    end

    it 'uses unlimited self-hosted defaults only when plan configuration is absent' do
      expect(account.captain_monthly_limit).to eq(
        { documents: 2, responses: 1 }.with_indifferent_access
      )

      account.update!(limits: {})
      expect(account.captain_monthly_limit).to eq(
        { documents: ChatwootApp.max_limit, responses: ChatwootApp.max_limit }.with_indifferent_access
      )
    end

    it 'fails closed when configured plan data is malformed' do
      InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_CLOUD_PLAN_LIMITS').update!(value: '{malformed')
      account.update!(limits: {})

      expect(account.captain_monthly_limit).to eq({ documents: 0, responses: 0 }.with_indifferent_access)
      expect(account.increment_response_usage).to be false
    end

    it 'fails closed when an account plan is missing from configured plan data' do
      InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_CLOUD_PLAN_LIMITS').update!(
        value: { startups: { documents: 10, responses: 20 } }.to_json
      )
      account.update!(limits: {})

      expect(account.captain_monthly_limit).to eq({ documents: 0, responses: 0 }.with_indifferent_access)
    end

    it 'resets response usage without replacing unrelated attributes' do
      account.update!(custom_attributes: account.custom_attributes.merge('captain_responses_usage' => 1))

      account.reset_response_usage

      expect(account.reload.custom_attributes).to include(
        'captain_responses_usage' => 0,
        'unrelated' => 'preserved'
      )
    end
  end
end
