# frozen_string_literal: true

# Public product identity is intentionally separate from the Chatwoot revision
# used for upstream compatibility, migrations and Hub protocol negotiation.
module Lla::ProductVersion
  def self.name
    Chatwoot.config.fetch(:product_name)
  end

  def self.current
    Chatwoot.config.fetch(:version)
  end

  def self.compatibility_product
    Chatwoot.config.fetch(:compatibility_product)
  end

  def self.compatibility_version
    Chatwoot.config.fetch(:compatibility_version)
  end
end
