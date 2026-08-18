# frozen_string_literal: true

# Typed configuration error for widget GeoIP country policy. Carries a stable code
# that the controller maps to a 422 without leaking provider internals.
class Lla::Widget::GeoConfigurationError < StandardError
  attr_reader :code

  def initialize(code)
    @code = code
    super(code)
  end
end
