# frozen_string_literal: true

# Default adapter. LLA custom domains are a first class capability that works
# without any external provider: DNS is pointed at the installation and ownership
# is proved through the LLA challenge endpoint. No egress happens here.
class Lla::CustomDomains::Providers::NullProvider
  def self.name_key
    'none'
  end

  def self.configured?
    true
  end

  def self.provision(_domain)
    { resource_id: nil, status: 'local' }
  end

  def self.check(_domain)
    { resource_id: nil, status: 'local' }
  end

  def self.teardown(_hostname, _resource_id)
    true
  end
end
