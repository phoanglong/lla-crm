# frozen_string_literal: true

# Tìm hoặc tạo người dùng từ khẳng định SAML của IdP, rồi áp vai trò theo nhóm.
#
# Hợp đồng lấy từ spec MIT spec/enterprise/builders/saml_user_builder_spec.rb.
# Ràng buộc quan trọng: người dùng đã tồn tại nhưng KHÔNG thuộc tài khoản đang
# đăng nhập thì phải bị từ chối — không được âm thầm thêm họ vào tài khoản, vì
# như vậy bất kỳ IdP nào cũng kéo được người dùng của tài khoản khác sang mình.
class SamlUserBuilder
  class AuthenticationFailed < StandardError; end

  # Spec gọi cả hai dạng: `new(auth_hash, account.id)` và
  # `new(auth_hash, account_id: account.id)`.
  def initialize(auth_hash, account_id = nil, **options)
    @auth_hash = auth_hash
    @account_id = account_id || options[:account_id]
  end

  def perform
    user = ::User.from_email(email)
    return create_user if user.blank?

    ensure_account_membership!(user)
    convert_to_saml(user)
    confirm(user)
    apply_role_mapping(user)
    user
  end

  private

  attr_reader :auth_hash

  def account
    @account ||= ::Account.find(@account_id)
  end

  def email
    auth_hash.dig('info', 'email')
  end

  def name
    auth_hash.dig('info', 'name').presence || email.to_s.split('@').first
  end

  def create_user
    password = "#{SecureRandom.hex(16)}aA1!"
    user = ::User.create(
      email: email,
      name: name,
      display_name: auth_hash.dig('info', 'first_name'),
      password: password,
      password_confirmation: password,
      provider: 'saml',
      confirmed_at: Time.current
    )
    return user unless user.persisted?

    account.account_users.create!(user: user, **account_user_attributes)
    user
  end

  def ensure_account_membership!(user)
    return if user.account_users.exists?(account_id: account.id)

    raise AuthenticationFailed, I18n.t('auth.saml.authentication_failed')
  end

  def convert_to_saml(user)
    return if user.provider == 'saml'

    user.update!(provider: 'saml')
  end

  def confirm(user)
    return if user.confirmed?

    user.update!(confirmed_at: Time.current)
  end

  def apply_role_mapping(user)
    attributes = mapped_attributes
    return if attributes.blank?

    user.account_users.find_by(account_id: account.id).update!(attributes)
  end

  def account_user_attributes
    mapped_attributes.presence || { role: :agent }
  end

  # Nhóm đầu tiên khớp bảng ánh xạ thắng. Không gộp nhiều nhóm vì hai nhóm có thể
  # ánh xạ tới hai vai trò mâu thuẫn và không có nguồn nào định nghĩa thứ tự ưu tiên.
  def mapped_attributes
    mapping = role_mappings.values_at(*saml_groups).compact.first
    return {} if mapping.blank?

    return { custom_role_id: mapping['custom_role_id'] } if mapping['custom_role_id'].present?

    { role: normalize_role(mapping['role']) }
  end

  def role_mappings
    settings = AccountSamlSettings.find_by(account_id: account.id)

    settings&.role_mappings.presence || {}
  end

  # Bảng ánh xạ có thể ghi vai trò bằng số (như enum trong DB) hoặc bằng tên.
  def normalize_role(value)
    value.is_a?(Integer) ? ::AccountUser.roles.key(value) : value
  end

  def saml_groups
    raw_info = auth_hash.dig('extra', 'raw_info') || {}

    Array(raw_info['groups'].presence || raw_info['memberOf'])
  end
end
