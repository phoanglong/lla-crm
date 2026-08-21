# frozen_string_literal: true

# Sinh vector embedding cho văn bản (RAG). Model lấy từ InstallationConfig
# CAPTAIN_EMBEDDING_MODEL, mặc định theo LlmConstants. Khoá API dùng cấu hình
# hệ thống (đã nạp qua Llm::Config / Lla::CaptainConfigSeeder).
class Captain::Llm::EmbeddingService
  class UnsupportedModel < StandardError; end
  class InvalidEmbedding < StandardError; end

  PROFILES = {
    'text-embedding-3-small' => 1536,
    'text-embedding-ada-002' => 1536
  }.freeze
  MAX_INPUT_BYTES = 32_000

  def self.embedding_model
    InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL')&.value.presence || LlmConstants::DEFAULT_EMBEDDING_MODEL
  end

  def self.embedding_profile
    model = embedding_model
    dimensions = PROFILES[model]
    raise UnsupportedModel, 'embedding model is not registered' if dimensions.blank?

    { model: model, dimensions: dimensions }
  end

  # account_id giữ trong hợp đồng khởi tạo để sau này hỗ trợ khoá theo account.
  def initialize(account_id:)
    @account_id = account_id
  end

  def get_embedding(text)
    value = text.to_s.scrub
    raise InvalidEmbedding, 'embedding input is invalid' if value.blank? || value.bytesize > MAX_INPUT_BYTES

    profile = self.class.embedding_profile
    Llm::Config.initialize!
    vector = Array(RubyLLM.embed(value, model: profile.fetch(:model)).vectors)
    raise InvalidEmbedding, 'embedding dimension does not match profile' unless vector.size == profile.fetch(:dimensions)
    raise InvalidEmbedding, 'embedding contains a non-finite value' unless vector.all? { |number| number.is_a?(Numeric) && number.finite? }

    vector
  end
end
