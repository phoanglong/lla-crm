# frozen_string_literal: true

# Đồng bộ khoá LLA AI từ ENV (Infisical → Coolify) vào InstallationConfig sau khi
# ứng dụng boot xong. Bỏ qua êm khi DB chưa sẵn sàng (assets precompile, migrate
# lần đầu) — lần boot phục vụ thật kế tiếp sẽ nạp.
Rails.application.config.after_initialize do
  if Lla::CaptainConfigSeeder::ENV_CONFIG_NAMES.any? { |name| ENV.fetch(name, nil).present? }
    begin
      Lla::CaptainConfigSeeder.perform if ActiveRecord::Base.connection.data_source_exists?('installation_configs')
    rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished, PG::ConnectionBad => e
      Rails.logger.warn("Lla::CaptainConfigSeeder bỏ qua: #{e.class}")
    end
  end
end
