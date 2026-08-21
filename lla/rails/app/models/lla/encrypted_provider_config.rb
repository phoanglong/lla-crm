# frozen_string_literal: true

# Kiểu của cột `provider_config`: mã hoá **đúng những khoá là bí mật của khách** khi ghi xuống
# CSDL, giải mã khi đọc lên.
#
# `provider_config` là một jsonb trộn hai loại giá trị: thứ dùng để định tuyến
# (`phone_number_id`, `business_account_id`, `application_id`) — có nơi truy vấn thẳng bằng
# `provider_config->>` — và khoá của khách (`api_key`, `access_token`, `api_secret`…). Mã hoá
# cả cột thì mất những truy vấn ấy.
#
# Làm ở tầng kiểu chứ không ở callback, vì callback thì có thứ tự: `after_create` của model
# (ví dụ `sync_templates` của WhatsApp) sẽ chạy xen vào giữa lúc cột còn đang là chuỗi mã.
# Ở đây cột chỉ là chuỗi mã bên trong đúng câu lệnh SQL, còn trong Ruby thì luôn là chữ thường.
#
#   attribute :provider_config, Lla::EncryptedProviderConfig.new(:api_key, :access_token)
class Lla::EncryptedProviderConfig < ActiveRecord::Type::Json
  def initialize(*secret_keys)
    @secret_keys = secret_keys.map(&:to_s).freeze
    super()
  end

  def type
    :jsonb
  end

  def deserialize(value)
    map_secrets(super) { |secret| decrypt(secret) }
  end

  def serialize(value)
    super(map_secrets(value) { |secret| encrypt(secret) })
  end

  private

  attr_reader :secret_keys

  # Khoá có thể là String (đọc từ CSDL) hoặc Symbol (vừa gán trong Ruby), nên so bằng `to_s`.
  def map_secrets(config, &)
    return config unless config.is_a?(::Hash)

    config.to_h { |key, value| [key, map_value(key, value, &)] }
  end

  def map_value(key, value)
    return value unless secret_keys.include?(key.to_s)
    return value unless value.is_a?(::String) && value.present?

    yield(value)
  end

  def encrypt(value)
    return value unless Chatwoot.encryption_configured?
    return value if encryptor.encrypted?(value)

    encryptor.encrypt(value)
  end

  # Không có khoá mà dữ liệu đã là mã nghĩa là khoá bị gỡ khỏi một bản cài đặt đang chạy — một
  # lỗi triển khai, và nó phải nổ chứ không được trả về chuỗi mã như thể đó là khoá.
  def decrypt(value)
    return value unless encryptor.encrypted?(value)

    encryptor.decrypt(value)
  end

  def encryptor
    ActiveRecord::Encryption.encryptor
  end
end
