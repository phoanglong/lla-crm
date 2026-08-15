# frozen_string_literal: true

# Công cụ HTTP tuỳ chỉnh cho trợ lý AI: gọi API ngoài với template liquid cho
# URL/body/phản hồi và các kiểu xác thực phổ biến. Hành vi HTTP nằm ở Toolable.
class Captain::CustomTool < ApplicationRecord
  include Concerns::Toolable
  include Concerns::SafeEndpointValidatable

  self.table_name = 'captain_custom_tools'

  PARAM_SCHEMA_REQUIRED_KEYS = %w[name type description].freeze
  PARAM_SCHEMA_ALLOWED_KEYS = %w[name type description required].freeze

  belongs_to :account

  enum http_method: { 'GET' => 'GET', 'POST' => 'POST' }
  enum auth_type: { none: 'none', bearer: 'bearer', basic: 'basic', api_key: 'api_key' }, _prefix: :auth

  validates :title, presence: true
  validates :slug, presence: true, uniqueness: { scope: :account_id }
  validates :endpoint_url, presence: true
  validate :validate_param_schema

  before_validation :generate_slug, on: :create

  scope :enabled, -> { where(enabled: true) }

  # jsonb giữ nguyên khoá symbol khi gán trong tiến trình — chuẩn hoá truy cập
  # theo khoá chuỗi cho mọi đường đọc.
  def auth_config
    config = super
    config.is_a?(Hash) ? config.with_indifferent_access : {}
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

    valid = param_schema.is_a?(Array) && param_schema.all? { |entry| valid_param_entry?(entry) }
    errors.add(:param_schema, 'is invalid') unless valid
  end

  def valid_param_entry?(entry)
    return false unless entry.is_a?(Hash)

    keys = entry.keys.map(&:to_s)
    (keys - PARAM_SCHEMA_ALLOWED_KEYS).empty? && (PARAM_SCHEMA_REQUIRED_KEYS - keys).empty?
  end
end
