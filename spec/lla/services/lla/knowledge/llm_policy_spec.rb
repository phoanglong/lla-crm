require 'rails_helper'

RSpec.describe Lla::Knowledge::LlmPolicy do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:portal) { create(:portal, account: account, homepage_link: 'https://docs.example.com/') }
  let(:operation) do
    Lla::Knowledge::GenerationOperation.create!(
      account: account,
      portal: portal,
      user: user,
      idempotency_digest: Digest::SHA256.hexdigest('llm-operation'),
      request_digest: Digest::SHA256.hexdigest('llm-request')
    )
  end
  let(:quota_reservations) do
    Lla::Captain::QuotaReservation.joins(:quota_ledger)
                                  .where(lla_captain_quota_ledgers: { account_id: account.id })
  end

  before do
    account.update!(custom_attributes: account.custom_attributes.merge(
      'lla_provider_consents' => {
        'openai' => { 'enabled' => true, 'version' => 'v1', 'accepted_at' => Time.current.iso8601 }
      }
    ))
  end

  around do |example|
    with_modified_env(
      'LLA_KNOWLEDGE_EXTERNAL_EGRESS_ENABLED' => 'true',
      'LLA_KNOWLEDGE_ARTICLE_GENERATION_ENABLED' => 'true',
      'LLA_KNOWLEDGE_WIDGET_TAGLINE_ENABLED' => 'true'
    ) { example.run }
  end

  it 'sanitizes writer output, records consent digest and redacts instrumentation input' do
    page = Lla::Knowledge::SourceAdapter::Page.new(
      url: 'https://docs.example.com/start', markdown: 'Untrusted source', page_title: 'Start'
    )
    item = instance_double(Lla::Knowledge::GenerationItem, id: 123)
    service = Captain::Llm::ArticleWriterService.new(
      account: account, source_pages: [page], operation: operation, item: item
    )
    allow(service).to receive(:make_api_call).and_return(
      message: { title: '<b>Safe</b>', description: 'Summary', content: '# Body<script>x</script>' },
      request_messages: [{ role: 'user', content: 'sensitive' }]
    )

    response = service.perform
    instrumentation = service.send(:build_instrumentation_params, 'model', [{ role: 'user', content: 'sensitive' }])

    expect(response[:message]).to include(title: 'Safe', content: '# Body')
    expect(response).not_to have_key(:request_messages)
    expect(operation.reload.provider_consent_digests.fetch('openai')).to match(/\A[0-9a-f]{64}\z/)
    expect(instrumentation).to include(messages: [], metadata: include(content_redacted: true, operation_id: operation.id))
    expect(quota_reservations.sole).to be_consumed
  end

  it 'fails closed before the LLM call when tenant consent is absent' do
    account.update!(custom_attributes: account.custom_attributes.except('lla_provider_consents'))
    service = Captain::Llm::WidgetTaglineService.new(account: account)
    expect(service).not_to receive(:make_api_call)

    expect { service.perform }.to raise_error(Lla::Knowledge::ProviderPolicy::Denied)
  end

  it 'returns only bounded plain text from the tagline schema result' do
    service = Captain::Llm::WidgetTaglineService.new(account: account)
    allow(service).to receive(:make_api_call).and_return(
      message: { tagline: '<b>How can we help</b>' }, request_messages: [{ role: 'user', content: 'private' }]
    )

    expect(service.perform).to eq(message: 'How can we help')
  end

  it 'replaces provider details and captured prompts with a stable public error' do
    service = Captain::Llm::WidgetTaglineService.new(account: account)
    allow(service).to receive(:make_api_call).and_return(
      error: 'provider token=secret-value', error_code: 503,
      request_messages: [{ role: 'user', content: 'private website content' }]
    )

    response = service.perform

    expect(response).to eq(error: 'lla_knowledge_provider_error', error_code: 503)
    expect(response.to_json).not_to match(/secret-value|private website content/)
    expect(quota_reservations.sole).to be_released
  end

  it 'makes zero LLM calls when the account generation budget is exhausted' do
    account.update!(limits: { 'captain_responses' => 0 })
    service = Captain::Llm::WidgetTaglineService.new(account: account)
    expect(service).not_to receive(:make_api_call)

    expect(service.perform).to include(code: 'lla_quota_exhausted', error_code: 429)
    expect(quota_reservations.sole).to be_rejected
  end
end
