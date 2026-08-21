# frozen_string_literal: true

# Sinh FAQ từ PDF đã upload lên OpenAI: đọc theo từng khoảng trang cho tới khi
# hết nội dung hoặc chạm trần vòng lặp. Dùng OpenAI client trực tiếp vì cần
# tham chiếu file_id trong nội dung hỏi.
class Captain::Llm::PaginatedFaqGeneratorService
  MAX_ITERATIONS = 20
  DEFAULT_PAGES_PER_CHUNK = 25

  attr_reader :iterations_completed, :total_pages_processed

  def initialize(document, pages_per_chunk: DEFAULT_PAGES_PER_CHUNK)
    @document = document
    @pages_per_chunk = pages_per_chunk
    @iterations_completed = 0
    @total_pages_processed = 0
  end

  def model
    Llm::FeatureRouter.resolve(feature: 'pdf_faq_generation', account: @document.account)[:model]
  end

  def generate
    raise CustomExceptions::Pdf::FaqGenerationError, 'Document has no OpenAI file id' if @document.openai_file_id.blank?

    faqs = []
    loop do
      chunk = process_page_chunk(next_page_range)
      @iterations_completed += 1
      @total_pages_processed += @pages_per_chunk
      faqs.concat(chunk[:faqs])

      break unless should_continue_processing?(faqs: chunk[:faqs], has_content: chunk[:has_content])
    end

    faqs
  end

  def should_continue_processing?(faqs:, has_content:)
    return false if @iterations_completed >= MAX_ITERATIONS
    return false if faqs.blank?

    has_content
  end

  private

  def next_page_range
    first_page = (@iterations_completed * @pages_per_chunk) + 1
    (first_page..(first_page + @pages_per_chunk - 1))
  end

  def process_page_chunk(page_range)
    response = client.chat(
      parameters: {
        model: model,
        response_format: { type: 'json_object' },
        messages: chunk_messages(page_range)
      }
    )
    parse_chunk(response.dig('choices', 0, 'message', 'content'))
  end

  def chunk_messages(page_range)
    [
      { role: 'system', content: Captain::Llm::SystemPromptsService.pdf_faq_generator(@document.account.locale_english_name) },
      {
        role: 'user',
        content: [
          { type: 'file', file: { file_id: @document.openai_file_id } },
          { type: 'text', text: "Generate FAQs strictly from pages #{page_range.first} to #{page_range.last} of the attached document." }
        ]
      }
    ]
  end

  def parse_chunk(content)
    parsed = JSON.parse(content.to_s)
    { faqs: Array(parsed['faqs']), has_content: parsed['has_content'] == true }
  rescue JSON::ParserError => e
    Rails.logger.error("Error parsing paginated LLM FAQ response: #{e.class}")
    { faqs: [], has_content: false }
  end

  # Endpoint của bản cài đặt bị bỏ qua ở đây: máy khách này luôn bắn thẳng tới api.openai.com
  # kể cả khi bản cài đặt trỏ sang một gateway riêng (OpenRouter, LiteLLM, máy chủ nội bộ).
  # Đó là một lỗi thật, không chỉ là rào cản của việc mang AI riêng.
  def client
    @client ||= OpenAI::Client.new(
      access_token: InstallationConfig.find_by!(name: 'CAPTAIN_OPEN_AI_API_KEY').value,
      uri_base: Lla::Ai::OpenaiEndpoint.resolve
    )
  end
end
