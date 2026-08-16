# frozen_string_literal: true

# Sinh lại bộ FAQ của một tài liệu. Chỉ thay bộ cũ sau khi generator trả về một
# tập hợp hợp lệ; thao tác thay thế và metadata PDF là nguyên tử.
class Captain::Documents::ResponseBuilderJob < ApplicationJob
  queue_as :low

  PDF_PAGES_PER_CHUNK = 25

  def perform(document)
    faqs, metadata = generate_faqs(document)
    faqs = normalize_faqs(faqs)
    return if faqs.empty?

    document.with_lock do
      document.responses.destroy_all
      create_responses(document, faqs)
      document.update!(metadata: metadata) if metadata
    end
  end

  private

  def generate_faqs(document)
    return [Captain::Llm::FaqGeneratorService.new(document: document).generate, nil] unless document.pdf_document?

    generator = Captain::Llm::PaginatedFaqGeneratorService.new(document, pages_per_chunk: PDF_PAGES_PER_CHUNK)
    faqs = generator.generate
    metadata = (document.metadata || {}).merge(
      'faq_generation' => {
        'total_pages_processed' => generator.total_pages_processed,
        'iterations_completed' => generator.iterations_completed
      }
    )
    [faqs, metadata]
  end

  def normalize_faqs(faqs)
    Array(faqs).filter_map do |faq|
      next unless faq.is_a?(Hash)

      attributes = faq.with_indifferent_access
      question = attributes[:question].to_s.strip
      answer = attributes[:answer].to_s.strip
      { 'question' => question, 'answer' => answer } if question.present? && answer.present?
    end
  end

  def create_responses(document, faqs)
    Array(faqs).each do |faq|
      document.responses.create!(
        question: faq['question'],
        answer: faq['answer'],
        assistant: document.assistant,
        account: document.account
      )
    end
  end
end
