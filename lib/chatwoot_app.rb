# frozen_string_literal: true

require 'pathname'

module ChatwootApp
  def self.root
    Pathname.new(File.expand_path('..', __dir__))
  end

  def self.max_limit
    100_000
  end

  # Giá trị ENV bị coi là "tắt". Không dùng ActiveModel::Type::Boolean vì tệp này
  # được require rất sớm, trước khi ActiveSupport/ActiveModel sẵn sàng.
  FALSEY_ENV_VALUES = %w[false f no n 0 off].freeze

  # ENV.fetch('X', false) trả về chuỗi, nên "false" cũng là truthy trong Ruby.
  # Hàm này đọc cờ ENV theo đúng nghĩa người vận hành mong đợi.
  def self.env_flag?(name)
    value = ENV.fetch(name, nil).to_s.strip.downcase
    return false if value.empty?

    # rubocop:disable Rails/NegateInclude -- exclude? là ActiveSupport; tệp này chỉ
    # require 'pathname' và được nạp trước Rails ở config/application.rb.
    !FALSEY_ENV_VALUES.include?(value)
    # rubocop:enable Rails/NegateInclude
  end

  # Giá trị ENV được coi là "bật" một cách rõ ràng.
  TRUTHY_ENV_VALUES = %w[true t yes y 1 on enabled].freeze

  # For gates that must fail closed: a capability is on only if the operator wrote
  # something that unambiguously means on. `env_flag?` answers the opposite question
  # — "is this not one of the words for off" — so a typo, an unfamiliar spelling, or
  # a value like "disabled" reads as ON there. That is the right default for a switch
  # such as DISABLE_ENTERPRISE, where the safe answer is "keep the flag set", and the
  # wrong one for a switch that opens external egress.
  def self.enabled_flag?(name)
    TRUTHY_ENV_VALUES.include?(ENV.fetch(name, nil).to_s.strip.downcase)
  end

  def self.enterprise?
    return false if env_flag?('DISABLE_ENTERPRISE')

    return @enterprise unless @enterprise.nil?

    @enterprise = root.join('enterprise').exist?
  end

  # Phần mở rộng do LLA phát triển (thay thế dần enterprise/ của upstream).
  # Xem ADR-OMCRM-032.
  def self.lla?
    return @lla unless @lla.nil?

    @lla = root.join('lla/rails/app').exist?
  end

  # --- Capability predicates ---
  # Thay dần các gate `if ChatwootApp.enterprise?` rải trong mã MIT. Mỗi wave của
  # chương trình LLA-DE-EE bật thêm một predicate khi năng lực tương ứng đã có
  # bản LLA; nhờ vậy không bao giờ lộ route/view cho tính năng chưa được viết.
  def self.custom_roles?
    enterprise? || lla?
  end

  def self.sla?
    enterprise? || lla?
  end

  # Voice routes must exist in pure LLA mode so signed provider callbacks can be
  # received. Account/channel/provider gates still default the capability off.
  def self.voice_calls?
    enterprise? || lla?
  end

  def self.chatwoot_cloud?
    enterprise? && GlobalConfig.get_value('DEPLOYMENT_ENV') == 'cloud'
  end

  def self.self_hosted_enterprise?
    enterprise? && !chatwoot_cloud? && GlobalConfig.get_value('INSTALLATION_PRICING_PLAN') == 'enterprise'
  end

  def self.custom?
    @custom ||= root.join('custom').exist?
  end

  def self.help_center_root
    ENV.fetch('HELPCENTER_URL', nil) || ENV.fetch('FRONTEND_URL', nil)
  end

  # Thứ tự QUAN TRỌNG: prepend_mod_with prepend theo đúng thứ tự này, module
  # prepend sau nằm gần đầu ancestor chain hơn. Đặt 'lla' cuối cùng để trong giai
  # đoạn chuyển tiếp (còn enterprise/) module Lla:: luôn thắng Enterprise::.
  def self.extensions
    extension_names = []
    extension_names << 'enterprise' if enterprise?
    extension_names << 'custom' if custom?
    extension_names << 'lla' if lla?
    extension_names
  end

  # Advanced search is available when an index is configured. It used to also
  # require the enterprise directory to exist, so removing that directory would
  # have silently switched every account back to SQL search with a configured
  # OpenSearch cluster sitting idle beside it.
  def self.advanced_search_allowed?
    ENV.fetch('OPENSEARCH_URL', nil).present?
  end

  def self.otel_enabled?
    otel_provider = InstallationConfig.find_by(name: 'OTEL_PROVIDER')&.value
    secret_key = InstallationConfig.find_by(name: 'LANGFUSE_SECRET_KEY')&.value

    otel_provider.present? && secret_key.present? && otel_provider == 'langfuse'
  end
end
