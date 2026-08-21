# frozen_string_literal: true

require 'rails_helper'

# The same bug has now appeared three times in this codebase: a security-relevant
# environment flag read through `ActiveModel::Type::Boolean`, whose cast answers
# "is this not one of my falsey words" rather than "did the operator say yes".
# `LLA_PROVIDER_*` (fixed in b374c6e), `ENABLE_PUSH_RELAY_SERVER` (6b9ba04), and the
# five found by review and by this file.
#
# `ChatwootApp.enabled_flag?` is the strict reader: on only for
# true/t/yes/y/1/on/enabled. Everything else, including "disabled", is off.
#
# This file states the rule for the flags that matter and then enforces it
# structurally, so the next one is caught by a failing test rather than by a review.
RSpec.describe 'security-relevant environment flags are read strictly' do # rubocop:disable RSpec/DescribeClass
  # Every one of these opens something: private-network egress, outbound HTTP from
  # assistant tools, deletion of an account that still owes a provider an action, a
  # platform migration endpoint, or signup that skips email confirmation.
  let(:strictly_read_flags) do
    {
      'SAFE_FETCH_ALLOW_PRIVATE_NETWORK' => -> { SafeFetch.allow_private_network? },
      'LLA_AI_CUSTOM_HTTP_TOOLS_ENABLED' => -> { Captain::Assistant.custom_http_tools_enabled? },
      'EMAIL_CHANNEL_MIGRATION' => -> { ChatwootApp.enabled_flag?('EMAIL_CHANNEL_MIGRATION') },
      'CW_API_ONLY_SERVER' => -> { ChatwootApp.enabled_flag?('CW_API_ONLY_SERVER') }
    }
  end

  # Values an operator might plausibly write meaning "off", every one of which the
  # permissive cast reads as ON.
  let(:meant_as_off) { ['disabled', 'no', 'off', 'nope', 'false ', 'FALSE', '', 'null', 'none'] }
  let(:meant_as_on) { %w[true t yes y 1 on enabled] }

  it 'reads every listed flag as off when it is unset' do
    strictly_read_flags.each do |flag, reader|
      with_modified_env(flag => nil) do
        expect(reader.call).to be(false), "#{flag} unset was read as ON"
      end
    end
  end

  it 'keeps every listed flag off for any value an operator could mean as off' do
    strictly_read_flags.each do |flag, reader|
      meant_as_off.each do |value|
        with_modified_env(flag => value) do
          expect(reader.call).to be(false), "#{flag}=#{value.inspect} was read as ON"
        end
      end
    end
  end

  it 'turns a flag on only for a value that unambiguously means on' do
    strictly_read_flags.each do |flag, reader|
      meant_as_on.each do |value|
        with_modified_env(flag => value) do
          expect(reader.call).to be(true), "#{flag}=#{value.inspect} was read as OFF"
        end
      end
    end
  end

  describe 'the custom-domain deletion override' do
    it 'refuses to be opened by a value that does not mean yes' do
      with_modified_env('LLA_CUSTOM_DOMAIN_ALLOW_ACCOUNT_DELETION_WITH_OBLIGATIONS' => 'disabled') do
        expect(ChatwootApp.enabled_flag?(Lla::CustomDomains::AccountDeletionSweep::OVERRIDE_FLAG)).to be(false)
      end
    end
  end

  # The structural half. A reviewer found three of these by reading; this finds the
  # fourth without one. Any ENV read cast through the permissive Active Model boolean
  # is reported, because an ENV value is an operator's word, not a form field.
  it 'has no environment flag left reading through the permissive cast' do
    roots = %w[app lib lla].map { |root| Rails.root.join(root) }
    offenders = roots.flat_map { |root| Dir.glob(root.join('**', '*.rb')) }.filter_map do |path|
      relative = Pathname.new(path).relative_path_from(Rails.root).to_s
      File.readlines(path, chomp: true).each_with_index.filter_map do |line, index|
        next unless line.include?('ActiveModel::Type::Boolean')
        next unless line.include?('ENV.fetch') || line.include?('ENV[')

        "#{relative}:#{index + 1}: #{line.strip}"
      end.presence
    end.flatten

    expect(offenders).to be_empty, <<~MESSAGE
      These read an environment flag with the permissive cast. Use
      ChatwootApp.enabled_flag? so only an explicit yes turns them on:

      #{offenders.join("\n")}
    MESSAGE
  end
end
