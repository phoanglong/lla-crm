# frozen_string_literal: true

# Tính vector nhúng cho một FAQ mới/đổi nội dung — không có vector thì
# FaqLookupTool không thể tìm thấy câu trả lời.
class Captain::Llm::ResponseEmbeddingJob < ApplicationJob
  queue_as :low

  def perform(response)
    embedding = Captain::Llm::EmbeddingService
                .new(account_id: response.account_id)
                .get_embedding("#{response.question}\n#{response.answer}")

    response.update_column(:embedding, embedding) # rubocop:disable Rails/SkipsModelValidations
  end
end
