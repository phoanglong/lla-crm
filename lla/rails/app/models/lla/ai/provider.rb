# frozen_string_literal: true

# Nhà cung cấp AI **của một tenant**: khoá của họ, endpoint của họ, mô hình của họ.
#
# `kind` quyết định cách nói chuyện (OpenAI, Anthropic, Gemini, Azure, hay bất kỳ endpoint
# tương thích OpenAI như OpenRouter/LiteLLM/Ollama/vLLM). `name` là cái tenant tự đặt và
# dùng để chỉ mô hình: `<name>/<model>` — ví dụ `noi-bo/llama-3.1-70b`.
class Lla::Ai::Provider < ApplicationRecord
  self.table_name = 'lla_ai_providers'

  KINDS = %w[openai anthropic gemini azure_openai openai_compatible].freeze
  # Endpoint tự đặt chỉ có nghĩa (và chỉ bắt buộc) với hai loại này; các loại khác có địa chỉ
  # cố định của nhà cung cấp.
  KINDS_REQUIRING_BASE = %w[azure_openai openai_compatible].freeze
  NAME_FORMAT = /\A[a-z0-9][a-z0-9_-]{0,63}\z/
  MAX_MODELS = 50

  belongs_to :account, class_name: '::Account'

  encrypts :api_key if Chatwoot.encryption_configured?

  store_accessor :config, :models

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :name, presence: true, format: { with: NAME_FORMAT }, uniqueness: { scope: :account_id }
  validates :api_base, length: { maximum: 512 }
  validate :require_api_base_for_custom_endpoints
  validate :require_encryption_for_key
  validate :validate_models
  validate :validate_api_base_scheme

  scope :enabled, -> { where(enabled: true) }

  # Mô hình tenant tự khai. Không có thì kết nối vẫn dùng được, chỉ là màn hình chọn mô hình
  # không có gì để gợi ý.
  def model_names
    Array(models).map(&:to_s).compact_blank
  end

  def offers?(model)
    model_names.include?(model.to_s)
  end

  private

  def require_api_base_for_custom_endpoints
    return unless KINDS_REQUIRING_BASE.include?(kind)
    return if api_base.present?

    errors.add(:api_base, 'is required for this provider kind')
  end

  # Khoá của khách nằm plaintext trong CSDL là điều không được phép xảy ra trong im lặng.
  def require_encryption_for_key
    return if api_key.blank? || Chatwoot.encryption_configured?

    errors.add(:api_key, 'requires Active Record encryption keys')
  end

  def validate_models
    return if models.blank?
    return errors.add(:models, 'must be a list of model names') unless models.is_a?(Array)
    return errors.add(:models, "cannot list more than #{MAX_MODELS} models") if models.length > MAX_MODELS
    return if models.all? { |model| model_name?(model) }

    errors.add(:models, 'must be non-empty names without a slash')
  end

  # Dấu `/` là ký tự ngăn cách trong `<nhà cung cấp>/<mô hình>`, nên tên mô hình khai ở đây
  # không được chứa nó.
  def model_name?(model)
    model.is_a?(String) && model.present? && model.exclude?('/')
  end

  # Endpoint là địa chỉ máy chủ sẽ nhận khoá của khách; chấp nhận một URL không rõ hình thù
  # là mở đường cho khoá đi tới nơi không ai định.
  def validate_api_base_scheme
    return if api_base.blank?

    uri = URI.parse(api_base)
    return if uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.blank?

    errors.add(:api_base, 'must be an https URL without credentials')
  rescue URI::InvalidURIError
    errors.add(:api_base, 'must be a valid URL')
  end
end
