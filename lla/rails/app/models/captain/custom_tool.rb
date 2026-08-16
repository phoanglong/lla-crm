# frozen_string_literal: true

# Công cụ HTTP tuỳ chỉnh cho trợ lý AI: gọi API ngoài với template liquid cho
# URL/body/phản hồi và các kiểu xác thực phổ biến. Hành vi HTTP nằm ở Toolable.
class Captain::CustomTool < ApplicationRecord
  include Concerns::Toolable
  include Concerns::SafeEndpointValidatable

  self.table_name = 'captain_custom_tools'

  PARAM_SCHEMA_REQUIRED_KEYS = %w[name type description].freeze
  PARAM_SCHEMA_ALLOWED_KEYS = %w[name type description required].freeze
  PARAM_SCHEMA_TYPES = %w[string number boolean array object].freeze
  AUTH_CONFIG_KEYS = {
    'none' => [],
    'bearer' => %w[token],
    'basic' => %w[username password],
    'api_key' => %w[name key]
  }.freeze
  RESERVED_HEADER_NAMES = %w[
    authorization connection content-length cookie host proxy-authorization
    transfer-encoding x-lla-account-id x-lla-assistant-id x-lla-contact-id
    x-lla-contact-inbox-id x-lla-contact-inbox-verified x-lla-conversation-id
    x-lla-conversation-display-id x-lla-tool-slug
  ].freeze
  MAX_PARAM_COUNT = 32
  MAX_CREDENTIAL_BYTES = 4_096

  belongs_to :account

  enum http_method: { 'GET' => 'GET', 'POST' => 'POST' }
  enum auth_type: { none: 'none', bearer: 'bearer', basic: 'basic', api_key: 'api_key' }, _prefix: :auth

  encrypts :auth_config_ciphertext if Chatwoot.encryption_configured?

  validates :title, presence: true, length: { maximum: 120 }
  validates :description, length: { maximum: 2_000 }
  validates :slug, presence: true, length: { maximum: 120 }, uniqueness: { scope: :account_id },
                   format: { with: /\Acustom_[a-z0-9_-]+\z/ }
  validates :endpoint_url, presence: true, length: { maximum: 2_048 }
  validates :request_template, :response_template, length: { maximum: 64.kilobytes }
  validate :validate_param_schema
  validate :validate_auth_config
  validate :require_encryption_for_credentials

  before_validation :clear_auth_config_without_authentication
  before_validation :promote_legacy_auth_config
  before_validation :generate_slug, on: :create

  scope :enabled, -> { where(enabled: true) }

  # Credential mới chỉ được ghi vào cột mã hóa. Cột jsonb cũ được đọc tạm trong
  # cửa sổ migration rồi xóa nội dung sau khi mã hóa thành công.
  def auth_config
    return @pending_auth_config if defined?(@pending_auth_config)

    encrypted_auth_config.presence || legacy_auth_config
  end

  def auth_config=(value)
    @pending_auth_config = normalize_auth_config(value)
    write_attribute(:auth_config, {})
    self.auth_config_ciphertext = @pending_auth_config.to_json if @pending_auth_config.present? && Chatwoot.encryption_configured?
    self.auth_config_ciphertext = nil if @pending_auth_config.empty?
  end

  def auth_configured?
    return false if auth_none?
    return @pending_auth_config.present? if defined?(@pending_auth_config)

    read_attribute_before_type_cast(:auth_config_ciphertext).present? || legacy_auth_config.present?
  end

  private

  # Slug sinh từ title với tiền tố custom_; trùng trong account thì gắn hậu tố
  # ngẫu nhiên. Slug đặt tay được giữ nguyên.
  def generate_slug
    return if slug.present? || title.blank?

    base = "custom_#{title.parameterize(separator: '_')}"
    candidate = base
    candidate = "#{base}_#{SecureRandom.alphanumeric(6).downcase}" while self.class.where(account_id: account_id).exists?(slug: candidate)
    self.slug = candidate
  end

  # Mỗi phần tử param_schema phải có đúng bộ khoá name/type/description
  # (required tuỳ chọn) — chặn cấu hình lệch hợp đồng với LLM.
  def validate_param_schema
    return if param_schema.blank?

    valid = param_schema.is_a?(Array) && param_schema.length <= MAX_PARAM_COUNT && param_schema.all? { |entry| valid_param_entry?(entry) }
    errors.add(:param_schema, 'is invalid') unless valid
  end

  def valid_param_entry?(entry)
    return false unless entry.is_a?(Hash)

    keys = entry.keys.map(&:to_s)
    normalized = entry.stringify_keys
    (keys - PARAM_SCHEMA_ALLOWED_KEYS).empty? && (PARAM_SCHEMA_REQUIRED_KEYS - keys).empty? &&
      normalized['name'].to_s.match?(/\A[a-zA-Z][a-zA-Z0-9_]{0,63}\z/) &&
      PARAM_SCHEMA_TYPES.include?(normalized['type'].to_s) && normalized['description'].to_s.bytesize <= 500
  end

  def validate_auth_config
    expected_keys = AUTH_CONFIG_KEYS.fetch(auth_type.to_s, [])
    return validate_empty_auth_config if expected_keys.empty?

    errors.add(:auth_config, 'is invalid') unless valid_credential_values?(expected_keys) && valid_api_key_header?
  end

  def validate_empty_auth_config
    errors.add(:auth_config, 'must be empty when authentication is disabled') if auth_config.present?
  end

  def valid_credential_values?(expected_keys)
    actual_keys = auth_config.keys.map(&:to_s)
    (actual_keys - expected_keys).empty? && expected_keys.all? do |key|
      value = auth_config[key].to_s
      value.present? && value.bytesize <= MAX_CREDENTIAL_BYTES
    end
  end

  def valid_api_key_header?
    !auth_api_key? || safe_api_key_header_name?
  end

  def require_encryption_for_credentials
    return if auth_config.blank? || Chatwoot.encryption_configured?

    errors.add(:auth_config, 'requires Active Record encryption keys')
  end

  def safe_api_key_header_name?
    header_name = auth_config['name'].to_s
    header_name.match?(/\A[A-Za-z][A-Za-z0-9-]{0,63}\z/) && RESERVED_HEADER_NAMES.exclude?(header_name.downcase)
  end

  def clear_auth_config_without_authentication
    self.auth_config = {} if auth_none? && auth_config.present?
  end

  def promote_legacy_auth_config
    return unless Chatwoot.encryption_configured? && auth_config_ciphertext.blank? && legacy_auth_config.present?

    self.auth_config = legacy_auth_config
  end

  def encrypted_auth_config
    return {} unless Chatwoot.encryption_configured?

    payload = auth_config_ciphertext
    return {} if payload.blank?

    JSON.parse(payload).with_indifferent_access
  rescue JSON::ParserError
    {}
  end

  def legacy_auth_config
    normalize_auth_config(self[:auth_config])
  end

  def normalize_auth_config(value)
    value.is_a?(Hash) ? value.deep_stringify_keys.with_indifferent_access : {}.with_indifferent_access
  end
end
