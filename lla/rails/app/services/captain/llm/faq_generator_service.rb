# frozen_string_literal: true

# Sinh FAQ từ nội dung một tài liệu web (markdown đã crawl) bằng LLM,
# trả về mảng {question, answer} cho ResponseBuilderJob ghi xuống.
class Captain::Llm::FaqGeneratorService
  def initialize(document:)
    @document = document
  end

  def generate
    Llm::Config.initialize!

    response = chat.ask(@document.content.to_s)
    parse_faqs(response&.content)
  rescue RubyLLM::Error => e
    Rails.logger.error("LLM API Error: #{e.message}")
    []
  end

  private

  def chat
    RubyLLM.chat(model: routed_model)
           .with_params(response_format: { type: 'json_object' })
           .with_instructions(Captain::Llm::SystemPromptsService.faq_generator(account_language))
  end

  def routed_model
    Llm::FeatureRouter.resolve(feature: 'document_faq_generation', account: @document.account)[:model]
  end

  def account_language
    @document.account.locale_english_name
  end

  def parse_faqs(content)
    return [] if content.blank?

    JSON.parse(content).fetch('faqs')
  rescue JSON::ParserError => e
    Rails.logger.error("Error in parsing GPT processed response: #{e.message}")
    []
  rescue KeyError
    []
  end
end
