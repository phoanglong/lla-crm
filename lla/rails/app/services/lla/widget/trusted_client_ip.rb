# frozen_string_literal: true

# Resolves the client IP to trust for widget geo decisions. X-Forwarded-For is only
# honoured when the direct connection peer is a configured trusted proxy; otherwise the
# unspoofable direct connection address is used so a client cannot forge its geo.
class Lla::Widget::TrustedClientIp
  def self.resolve(remote_ip:, remote_addr:)
    new(remote_ip: remote_ip, remote_addr: remote_addr).resolve
  end

  def initialize(remote_ip:, remote_addr:)
    @remote_ip = remote_ip
    @remote_addr = remote_addr.to_s
  end

  def resolve
    direct_peer_trusted? ? @remote_ip : @remote_addr
  end

  private

  def direct_peer_trusted?
    return false if @remote_addr.blank?

    address = IPAddr.new(@remote_addr)
    trusted_proxy_ranges.any? { |range| range.respond_to?(:include?) && range.include?(address) }
  rescue IPAddr::InvalidAddressError
    false
  end

  # Rails is explicit that setting `config.action_dispatch.trusted_proxies` to an
  # enumerable *replaces* the default set (see ActionDispatch::RemoteIp). Unioning
  # it with the defaults would silently re-trust every RFC1918 peer for an operator
  # who deliberately narrowed the set to their edge load balancer, which is the
  # whole point of narrowing it. So: configured means configured.
  def trusted_proxy_ranges
    configured = Array(Rails.application.config.action_dispatch.trusted_proxies)
    return configured if configured.any?

    ActionDispatch::RemoteIp::TRUSTED_PROXIES
  end
end
