# frozen_string_literal: true

# LLA ownership of every outbound call to Chatwoot's hosted hub.
#
# Prepended to `ChatwootHub`'s singleton class by
# `ChatwootHub.singleton_class.prepend_mod_with('ChatwootHub')`. See
# `Lla::Hub::EgressPolicy` for what each switch covers and why the default is off.
#
# Nothing here weakens what the base class does when a call *is* permitted; it
# decides whether the call happens at all.
module Lla::ChatwootHub
  def sync_with_hub
    return Lla::Hub::EgressPolicy.refused('sync_with_hub') unless Lla::Hub::EgressPolicy.telemetry_allowed?

    super
  end

  def emit_event(event_name, event_data)
    return Lla::Hub::EgressPolicy.refused('emit_event') unless Lla::Hub::EgressPolicy.telemetry_allowed?

    super
  end

  def register_instance(company_name, owner_name, owner_email)
    return Lla::Hub::EgressPolicy.refused('register_instance') unless Lla::Hub::EgressPolicy.registration_allowed?

    super
  end

  def send_push(fcm_options)
    return Lla::Hub::EgressPolicy.refused('send_push') unless Lla::Hub::EgressPolicy.push_relay_allowed?

    super
  end

  def send_push_with_response(fcm_options)
    return Lla::Hub::EgressPolicy.refused('send_push_with_response') unless Lla::Hub::EgressPolicy.push_relay_allowed?

    super
  end

  # The plan this installation runs on is a local fact. It used to be read from an
  # `InstallationConfig` row that only the hub wrote, so with the hub unreachable —
  # or simply not asked — every premium capability silently reported "community"
  # and turned itself off.
  def pricing_plan
    Lla::Entitlements.plan
  end

  def pricing_plan_quantity
    Lla::Entitlements.seat_count
  end
end
