# frozen_string_literal: true

# Sinh lại bộ FAQ của một tài liệu: xoá câu trả lời cũ rồi tạo mới từ nội dung.
# PDF dùng generator phân trang (đọc file qua OpenAI) và lưu metadata tiến trình.
class Captain::Documents::ResponseBuilderJob < ApplicationJob
  queue_as :low

  PDF_PAGES_PER_CHUNK = 25

  def perform(document)
    document.responses.destroy_all

    if document.pdf_document?
      build_responses_from_pdf(document)
    else
      faqs = Captain::Llm::FaqGeneratorService.new(document: document).generate
      create_responses(document, faqs)
    end
  end

  private

  def build_responses_from_pdf(document)
    generator = Captain::Llm::PaginatedFaqGeneratorService.new(document, pages_per_chunk: PDF_PAGES_PER_CHUNK)
    create_responses(document, generator.generate)

    document.update!(
      metadata: (document.metadata || {}).merge(
        'faq_generation' => {
          'total_pages_processed' => generator.total_pages_processed,
          'iterations_completed' => generator.iterations_completed
        }
      )
    )
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
