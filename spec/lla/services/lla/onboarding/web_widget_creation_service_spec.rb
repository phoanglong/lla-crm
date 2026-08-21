require 'rails_helper'

RSpec.describe Lla::Onboarding::WebWidgetCreationService do
  let(:account) do
    create(:account, name: 'Acme Inc', custom_attributes: {
             'website' => 'acme.com',
             'brand_info' => { 'slogan' => 'Fallback slogan', 'description' => 'Fallback description' }
           })
  end
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:service) { Onboarding::WebWidgetCreationService.new(account, user) }

  before do
    stub_const('Captain::Llm::WidgetTaglineService', Class.new do
      def initialize(account:); end

      def with_quota_idempotency_key(_key) = self

      def perform; end
    end)
  end

  it 'uses local brand text without invoking the LLM when consent is absent' do
    expect(Captain::Llm::WidgetTaglineService).not_to receive(:new)

    expect(service.perform.channel.welcome_tagline).to eq('Fallback slogan')
  end

  it 'uses a generated tagline only when every egress gate is granted' do
    grant_openai_consent
    llm = instance_double(Captain::Llm::WidgetTaglineService, perform: { message: '  Generated tagline  ' })
    allow(llm).to receive(:with_quota_idempotency_key).and_return(llm)
    allow(Captain::Llm::WidgetTaglineService).to receive(:new).with(account: account).and_return(llm)

    with_tagline_egress do
      expect(service.perform.channel.welcome_tagline).to eq('Generated tagline')
    end
  end

  it 'falls back and logs no provider error detail when generation raises' do
    grant_openai_consent
    logged = []
    llm = instance_double(Captain::Llm::WidgetTaglineService)
    allow(llm).to receive(:with_quota_idempotency_key).and_return(llm)
    allow(llm).to receive(:perform).and_raise(StandardError, 'provider-secret-detail')
    allow(Captain::Llm::WidgetTaglineService).to receive(:new).and_return(llm)
    allow(Rails.logger).to receive(:warn) { |message| logged << message }

    with_tagline_egress do
      expect(service.perform.channel.welcome_tagline).to eq('Fallback slogan')
    end

    expect(logged.join).to include('error_class=StandardError')
    expect(logged.join).not_to include('provider-secret-detail')
  end

  private

  def grant_openai_consent
    account.update!(custom_attributes: account.custom_attributes.merge(
      'lla_provider_consents' => {
        'openai' => { 'enabled' => true, 'version' => '2026-08-17', 'accepted_at' => Time.current.iso8601 }
      }
    ))
  end

  def with_tagline_egress(&)
    with_modified_env(
      'LLA_KNOWLEDGE_EXTERNAL_EGRESS_ENABLED' => 'true',
      'LLA_KNOWLEDGE_WIDGET_TAGLINE_ENABLED' => 'true',
      &
    )
  end
end
