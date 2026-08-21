# frozen_string_literal: true

module Lla::Knowledge::LlmPolicy
  private

  def authorize_knowledge_llm!(capability)
    Lla::Knowledge::ProviderPolicy.authorize_egress!(
      account: account, provider: :openai, capability: capability
    )
    record_openai_consent!
  end

  def safe_knowledge_response(response)
    return { error: 'lla_knowledge_provider_error', error_code: 502 } unless response.is_a?(Hash)

    error = response[:error] || response['error']
    unless error
      message = response[:message] || response['message']
      return response.except(:request_messages, 'request_messages', 'message').merge(message: message)
    end

    { error: 'lla_knowledge_provider_error', error_code: response[:error_code] || response['error_code'] || 502 }
  end

  def build_instrumentation_params(model, _messages)
    super(model, []).merge(
      messages: [],
      metadata: { operation_id: knowledge_operation&.id, content_redacted: true }.compact
    )
  end

  def knowledge_operation
    respond_to?(:operation, true) ? operation : nil
  end

  def record_openai_consent!
    return if knowledge_operation.blank?

    digest = Lla::Knowledge::ProviderPolicy.consent_digest(account, :openai)
    raise Lla::Knowledge::ProviderPolicy::Denied if digest.blank?

    knowledge_operation.with_lock do
      knowledge_operation.update!(
        provider_consent_digests: knowledge_operation.provider_consent_digests.merge('openai' => digest)
      )
    end
  end
end
