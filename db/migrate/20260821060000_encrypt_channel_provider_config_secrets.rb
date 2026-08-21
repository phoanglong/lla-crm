# frozen_string_literal: true

# Khoá của khách trong `provider_config` cho tới nay nằm ở dạng chữ thường: khoá API 360dialog,
# access token của Meta app tenant mang tới, khoá Bandwidth, token OAuth Gmail/Outlook. Model
# nay mã hoá chúng khi ghi, nhưng những hàng đã có sẽ chỉ được mã hoá ở lần lưu tiếp theo —
# mà có hàng thì hàng năm không ai lưu lại. Bản di trú này mã hoá tại chỗ.
class EncryptChannelProviderConfigSecrets < ActiveRecord::Migration[7.1]
  SECRETS = {
    'channel_whatsapp' => %w[api_key api_secret access_token app_secret webhook_verify_token verification_pin],
    'channel_sms' => %w[api_key api_secret callback_password],
    'channel_email' => %w[access_token refresh_token]
  }.freeze

  def up
    # Không có khoá mã hoá thì không có gì để mã hoá bằng. Nói ra rồi đi tiếp, vì đường đọc
    # vẫn chấp nhận chữ thường và bản cài đặt vẫn chạy được như trước.
    return say('Active Record encryption is not configured; provider_config secrets left as they are') unless Chatwoot.encryption_configured?

    SECRETS.each { |table, keys| encrypt_table(table, keys) }
  end

  # Đường đọc chấp nhận cả hai dạng, nên không cần giải mã ngược.
  def down; end

  private

  def encrypt_table(table, keys)
    return unless table_exists?(table)

    count = 0
    each_row(table) do |id, config|
      encrypted = encrypt_config(config, keys)
      next if encrypted == config

      write_config(table, id, encrypted)
      count += 1
    end
    say("#{table}: encrypted secrets in #{count} row(s)")
  end

  def each_row(table)
    select_all("SELECT id, provider_config FROM #{table} WHERE provider_config IS NOT NULL").each do |row|
      config = row['provider_config']
      config = JSON.parse(config) if config.is_a?(String)
      next unless config.is_a?(Hash) && config.present?

      yield row['id'], config
    end
  end

  def encrypt_config(config, keys)
    encryptor = ActiveRecord::Encryption.encryptor
    config.to_h do |key, value|
      next [key, value] unless keys.include?(key) && value.is_a?(String) && value.present?
      next [key, value] if encryptor.encrypted?(value)

      [key, encryptor.encrypt(value)]
    end
  end

  def write_config(table, id, config)
    execute(
      ActiveRecord::Base.sanitize_sql_array(
        ["UPDATE #{table} SET provider_config = ?::jsonb WHERE id = ?", config.to_json, id]
      )
    )
  end
end
