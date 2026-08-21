require 'rails_helper'

RSpec.describe Captain::Articles::TranslateJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:portal) { create(:portal, account: account, config: { allowed_locales: %w[en es] }) }
  let(:category) { create(:category, account: account, portal: portal, locale: 'es') }
  let(:article) do
    create(:article, account: account, portal: portal, locale: 'en',
                     title: 'Reset password', description: 'A short guide', content: 'Open settings')
  end

  around do |example|
    account.enable_features!('captain_tasks')
    account.update!(custom_attributes: account.custom_attributes.merge(
      'lla_provider_consents' => {
        'openai' => { 'enabled' => true, 'version' => '2026-08-17', 'accepted_at' => Time.current.iso8601 }
      }
    ))
    with_modified_env(
      'LLA_KNOWLEDGE_EXTERNAL_EGRESS_ENABLED' => 'true',
      'LLA_KNOWLEDGE_ARTICLE_TRANSLATION_ENABLED' => 'true'
    ) { example.run }
  end

  def build_operation(force: false)
    Lla::Knowledge::TranslationOperationService.new(
      account: account,
      portal: portal,
      user: user,
      articles: [article],
      target_locale: 'es',
      target_category: category,
      force: force,
      idempotency_key: "translation:#{SecureRandom.hex(8)}"
    ).perform
  end

  def stub_translations
    responses = {
      title: '<b>Restablecer contraseña</b>',
      description: '<i>Una guía breve</i>',
      content: '[Ajustes](javascript:alert(1))<script>bad()</script> Abra ajustes'
    }
    allow(Captain::Llm::ArticleTranslationService).to receive(:new) do |**arguments|
      service = instance_double(Captain::Llm::ArticleTranslationService)
      allow(service).to receive(:with_quota_idempotency_key).and_return(service)
      allow(service).to receive(:perform).and_return(message: responses.fetch(arguments.fetch(:type)))
      service
    end
  end

  it 'creates one sanitized draft translation and records its durable result' do
    operation = build_operation
    stub_translations

    described_class.perform_now(operation.outboxes.sole.id)

    translated = operation.items.sole.reload.output_article
    expect(translated).to have_attributes(
      account_id: account.id,
      portal_id: portal.id,
      associated_article_id: article.id,
      locale: 'es',
      status: 'draft',
      title: 'Restablecer contraseña',
      description: 'Una guía breve'
    )
    expect(translated.content).to include('[Ajustes](#)', 'Abra ajustes')
    expect(translated.content).not_to include('javascript:', '<script>')
    expect(operation.reload).to have_attributes(state: 'completed', finished_items: 1, failed_items: 0)
    expect(translated.meta.dig('lla_translation', 'operation_id')).to eq(operation.id)
  end

  it 'preserves an existing translation when force is false' do
    existing = create(
      :article,
      account: account,
      portal: portal,
      locale: 'es',
      associated_article_id: article.id,
      title: 'Existing translation'
    )
    operation = build_operation
    stub_translations

    described_class.perform_now(operation.outboxes.sole.id)

    expect(existing.reload.title).to eq('Existing translation')
    expect(operation.items.sole.reload).to have_attributes(state: 'failed', last_error_code: 'translation_translation_conflict')
    expect(operation.reload).to have_attributes(state: 'completed_with_errors', failed_items: 1)
  end

  it 'updates an existing translation as a draft only when force is explicit' do
    existing = create(
      :article,
      account: account,
      portal: portal,
      locale: 'es',
      associated_article_id: article.id,
      title: 'Existing translation',
      status: :published
    )
    operation = build_operation(force: true)
    stub_translations

    described_class.perform_now(operation.outboxes.sole.id)

    expect(existing.reload).to have_attributes(title: 'Restablecer contraseña', status: 'draft')
    expect(operation.items.sole.reload.output_article_id).to eq(existing.id)
  end

  it 'fails closed without provider work when source content changed after scheduling' do
    operation = build_operation
    article.update!(content: 'Changed after the operation was accepted')

    expect(Captain::Llm::ArticleTranslationService).not_to receive(:new)
    described_class.perform_now(operation.outboxes.sole.id)

    expect(operation.items.sole.reload).to have_attributes(state: 'failed', last_error_code: 'translation_stale_source')
  end
end
