# frozen_string_literal: true

# Cấu hình SAML của một tài khoản.
#
# Hợp đồng lấy từ nguồn MIT:
# - db/schema.rb — bảng account_saml_settings (sso_url, certificate, sp_entity_id,
#   idp_entity_id, role_mappings)
# - spec/enterprise/models/account_saml_settings_spec.rb — đặc tả hành vi chạy được
# - app/javascript/dashboard/routes/dashboard/settings/security/components/SamlSettings.vue
#   — giao diện đọc id, sso_url, certificate, sp_entity_id, idp_entity_id, fingerprint
class AccountSamlSettings < ApplicationRecord
  belongs_to :account

  validates :sso_url, presence: true
  validates :certificate, presence: true
  validates :idp_entity_id, presence: true

  before_validation :assign_sp_entity_id, on: :create

  # Bật SAML cho tài khoản là đổi cách đăng nhập của toàn bộ thành viên, nên phải
  # đồng bộ provider của họ. Chạy sau commit vì job đọc lại bản ghi từ DB.
  after_create_commit :switch_account_users_to_saml
  after_destroy_commit :restore_account_users_provider

  def saml_enabled?
    sso_url.present? && certificate.present?
  end

  # Dấu vân tay SHA1 viết hoa, ngăn cách bằng dấu hai chấm — đúng dạng các IdP
  # (Okta, Entra ID, Google Workspace) hiển thị để người quản trị đối chiếu.
  def certificate_fingerprint
    return if certificate.blank?

    der = OpenSSL::X509::Certificate.new(certificate).to_der
    OpenSSL::Digest.new('SHA1', der).to_s.upcase.scan(/../).join(':')
  rescue OpenSSL::X509::CertificateError
    nil
  end

  private

  def assign_sp_entity_id
    return if sp_entity_id.present?

    self.sp_entity_id = "#{ENV.fetch('FRONTEND_URL', 'http://localhost:3000')}/saml/sp/#{account_id}"
  end

  def switch_account_users_to_saml
    Saml::UpdateAccountUsersProviderJob.perform_later(account_id, 'saml')
  end

  def restore_account_users_provider
    Saml::UpdateAccountUsersProviderJob.perform_later(account_id, 'email')
  end
end
