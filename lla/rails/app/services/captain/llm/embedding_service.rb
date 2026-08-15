# frozen_string_literal: true

# Sinh vector embedding cho văn bản (RAG). Model lấy từ InstallationConfig
# CAPTAIN_EMBEDDING_MODEL, mặc định theo LlmConstants. Khoá API dùng cấu hình
# hệ thống (đã nạp qua Llm::Config / Lla::CaptainConfigSeeder).
class Captain::Llm::EmbeddingService
  def self.embedding_model
    InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL')&.value.presence || LlmConstants::DEFAULT_EMBEDDING_MODEL
  end

  # account_id giữ trong hợp đồng khởi tạo để sau này hỗ trợ khoá theo account.
  def initialize(account_id:)
    @account_id = account_id
  end

  def get_embedding(text)
    Llm::Config.initialize!
    RubyLLM.embed(text, model: self.class.embedding_model).vectors
  end
end
