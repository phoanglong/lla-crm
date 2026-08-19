# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Account, type: :model do
  include ActiveJob::TestHelper

  describe 'associations' do
    it { is_expected.to have_many(:custom_roles).dependent(:destroy_async) }
  end

  describe '#selected_feature_flags=' do
    it 'keeps advanced assignment enabled when assignment v2 is selected for a business account' do
      account = build(:account, custom_attributes: { 'plan_name' => 'Business' })

      account.selected_feature_flags = [:feature_assignment_v2]

      expect(account).to be_feature_assignment_v2
      expect(account).to be_feature_advanced_assignment
    end

    it 'disables advanced assignment when assignment v2 is not selected' do
      account = build(:account, custom_attributes: { 'plan_name' => 'Business' })
      account.enable_features(:assignment_v2, :advanced_assignment)

      account.selected_feature_flags = []

      expect(account).not_to be_feature_assignment_v2
      expect(account).not_to be_feature_advanced_assignment
    end
  end

  context 'with usage_limits' do
    let(:captain_limits) do
      {
        :startups => { :documents => 100, :responses => 100 },
        :business => { :documents => 200, :responses => 300 },
        :enterprise => { :documents => 300, :responses => 500 }
      }.with_indifferent_access
    end
    let(:account) { create(:account, { custom_attributes: { plan_name: 'startups' } }) }
    let(:assistant) { create(:captain_assistant, account: account) }

    before do
      create(:installation_config, name: 'ACCOUNT_AGENTS_LIMIT', value: 20)
    end

    describe 'when captain limits are configured' do
      before do
        create_list(:captain_document, 3, account: account, assistant: assistant, status: :available)
        create(:installation_config, name: 'CAPTAIN_CLOUD_PLAN_LIMITS', value: captain_limits.to_json)
      end

      ## Document
      it 'updates document count accurately' do
        account.update_document_usage
        expect(account.custom_attributes['captain_documents_usage']).to eq(3)
      end

      it 'handles zero documents' do
        account.captain_documents.destroy_all
        account.update_document_usage
        expect(account.custom_attributes['captain_documents_usage']).to eq(0)
      end

      it 'reflects document limits' do
        document_limits = account.usage_limits[:captain][:documents]

        expect(document_limits[:consumed]).to eq 3
        expect(document_limits[:current_available]).to eq captain_limits[:startups][:documents] - 3
      end

      ## Responses
      it 'incrementing responses updates usage_limits' do
        account.increment_response_usage

        responses_limits = account.usage_limits[:captain][:responses]

        expect(account.custom_attributes['captain_responses_usage']).to eq 1
        expect(responses_limits[:consumed]).to eq 1
        expect(responses_limits[:current_available]).to eq captain_limits[:startups][:responses] - 1
      end

      it 'reseting responses limits updates usage_limits' do
        account.custom_attributes['captain_responses_usage'] = 30
        account.save!

        responses_limits = account.usage_limits[:captain][:responses]

        expect(responses_limits[:consumed]).to eq 30
        expect(responses_limits[:current_available]).to eq captain_limits[:startups][:responses] - 30

        account.reset_response_usage
        responses_limits = account.usage_limits[:captain][:responses]

        expect(account.custom_attributes['captain_responses_usage']).to eq 0
        expect(responses_limits[:consumed]).to eq 0
        expect(responses_limits[:current_available]).to eq captain_limits[:startups][:responses]
      end

      it 'returns monthly limit accurately' do
        %w[startups business enterprise].each do |plan|
          account.custom_attributes = { 'plan_name': plan }
          account.save!
          expect(account.captain_monthly_limit).to eq captain_limits[plan]
        end
      end

      it 'current_available is never out of bounds' do
        account.custom_attributes['captain_responses_usage'] = 3000
        account.save!

        responses_limits = account.usage_limits[:captain][:responses]
        expect(responses_limits[:consumed]).to eq 3000
        expect(responses_limits[:current_available]).to eq 0

        account.custom_attributes['captain_responses_usage'] = -100
        account.save!

        responses_limits = account.usage_limits[:captain][:responses]
        expect(responses_limits[:consumed]).to eq 0
        expect(responses_limits[:current_available]).to eq captain_limits[:startups][:responses]
      end
    end

    describe 'when captain limits are not configured' do
      it 'returns default values' do
        account.custom_attributes = { 'plan_name': 'unknown' }
        expect(account.captain_monthly_limit).to eq(
          { documents: ChatwootApp.max_limit, responses: ChatwootApp.max_limit }.with_indifferent_access
        )
      end
    end

    describe 'when limits are configured for an account' do
      before do
        create(:installation_config, name: 'CAPTAIN_CLOUD_PLAN_LIMITS', value: captain_limits.to_json)
        account.update(limits: { captain_documents: 5555, captain_responses: 9999 })
      end

      it 'returns limits based on custom attributes' do
        usage_limits = account.usage_limits
        expect(usage_limits[:captain][:documents][:total_count]).to eq(5555)
        expect(usage_limits[:captain][:responses][:total_count]).to eq(9999)
      end
    end

    describe 'audit logs' do
      it 'returns audit logs' do
        # checking whether associated_audits method is present
        expect(account.associated_audits.present?).to be false
      end

      it 'creates audit logs when account is updated' do
        account.update(name: 'New Name')
        expect(Audited::Audit.where(auditable_type: 'Account', action: 'update').count).to eq 1
      end
    end

    it 'returns max limits from global config when enterprise version' do
      expect(account.usage_limits[:agents]).to eq(20)
    end

    it 'returns max limits from account when enterprise version' do
      account.update(limits: { agents: 10 })
      expect(account.usage_limits[:agents]).to eq(10)
    end

    it 'returns max limits from global config if account limit is absent' do
      account.update(limits: { agents: '' })
      expect(account.usage_limits[:agents]).to eq(20)
    end

    it 'returns max limits from app limit if account limit and installation config is absent' do
      account.update(limits: { agents: '' })
      InstallationConfig.where(name: 'ACCOUNT_AGENTS_LIMIT').update(value: '')

      expect(account.usage_limits[:agents]).to eq(ChatwootApp.max_limit)
    end
  end
end
