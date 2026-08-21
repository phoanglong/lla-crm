# frozen_string_literal: true

# Nạp cấu hình Captain/LLA AI từ biến môi trường vào InstallationConfig lúc boot.
#
# ADR-OMCRM-033: Infisical là nguồn sự thật cho khoá hệ thống — Coolify đọc
# Infisical và bơm vào container qua ENV; bước này đưa ENV vào InstallationConfig
# (nơi mã MIT lib/captain + lib/llm đọc). ENV thắng giá trị cũ trong DB: đổi khoá
# ở Infisical + redeploy là xong, không dán tay vào Super Admin.
class Lla::CaptainConfigSeeder
  ENV_CONFIG_NAMES = %w[
    CAPTAIN_OPEN_AI_API_KEY
    CAPTAIN_OPEN_AI_MODEL
    CAPTAIN_OPEN_AI_ENDPOINT
    CAPTAIN_EMBEDDING_MODEL
    CAPTAIN_FIRECRAWL_API_KEY
  ].freeze

  def self.perform
    changed = false

    ENV_CONFIG_NAMES.each do |name|
      value = ENV.fetch(name, nil)
      next if value.blank?

      config = InstallationConfig.find_or_initialize_by(name: name)
      next if config.persisted? && config.value == value

      config.value = value
      config.save!
      changed = true
    end

    GlobalConfig.clear_cache if changed
  end
end
