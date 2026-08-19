# frozen_string_literal: true

# Whether this installation may talk to Chatwoot's hosted hub, and about what.
#
# The inherited behaviour was outbound by default. On a schedule,
# `ChatwootHub.sync_with_hub` posted the installation identifier, host and version
# **plus account, user, inbox, conversation and message counts** to
# `hub.2.chatwoot.com`; `register_instance` posted the owner's company name, name
# and email address at install time, with `subscribed_to_mailers: true`; and
# `emit_event` posted arbitrary events. The only brake was a `DISABLE_TELEMETRY`
# environment variable that nothing sets, and it did not cover registration at all.
#
# For a product deployed on customer premises in one jurisdiction, that is an
# outbound flow of business metrics and a named person's email address to a third
# party that the operator never agreed to. Every one of these is off unless the
# operator turns it on, each independently, and each read with the strict
# fail-closed reader — a misspelt value means off.
module Lla::Hub::EgressPolicy
  TELEMETRY_FLAG = 'LLA_HUB_TELEMETRY_ENABLED'
  REGISTRATION_FLAG = 'LLA_HUB_REGISTRATION_ENABLED'
  PUSH_RELAY_FLAG = 'LLA_HUB_PUSH_RELAY_ENABLED'

  module_function

  # Instance metrics and version pings.
  def telemetry_allowed?
    ChatwootApp.enabled_flag?(TELEMETRY_FLAG)
  end

  # Installation registration, which carries the owner's name and email.
  def registration_allowed?
    ChatwootApp.enabled_flag?(REGISTRATION_FLAG)
  end

  # Mobile push relayed through the hub. This one is a functional dependency
  # rather than telemetry: with it off, push notifications do not leave the
  # installation, which is the correct default for a deployment that has not
  # agreed to route its notifications through a third party, and which the
  # operator has to opt into knowingly.
  def push_relay_allowed?
    ChatwootApp.enabled_flag?(PUSH_RELAY_FLAG)
  end

  def refused(operation)
    Rails.logger.info(
      { event: 'lla_hub_egress_refused', operation: operation }.to_json
    )
    nil
  end
end
