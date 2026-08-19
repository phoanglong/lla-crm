# frozen_string_literal: true

require 'rails_helper'

# A regression guard, not a feature test. Every path that made this installation
# talk to a machine Chatwoot operates was removed rather than switched off, and
# this file fails if any of them comes back — by a merge, a cherry-pick from
# upstream, or a well-meaning restoration of "the changelog card".
RSpec.describe 'no connection through a Chatwoot-operated server' do # rubocop:disable RSpec/DescribeClass
  # Hosts that belong to Chatwoot's own infrastructure: the marketing site, the
  # hosted app, the docs, the help centre, the hub and its staging siblings.
  let(:host_pattern) { /\b[a-z0-9-]*(?:\.[a-z0-9-]+)*\.?chatwoot\.(?:com|dev|io|help)\b/i }

  let(:roots) { %w[app lib config db] + ['lla'] }

  # Test data, storybook fixtures and the specs themselves are neither shipped to
  # a browser nor executed by the server, so a Chatwoot URL in them is a string,
  # not a destination.
  let(:excluded_path) do
    %r{
      (^|/)(spec|specs|stories|story|fixtures)(/|$)
      | \.spec\.(js|ts)$
      | \.story\.(js|ts|vue)$
      | (^|/)fixtures\.js$
    }x
  end

  let(:text_extensions) { %w[.rb .erb .js .ts .vue .json .yml .yaml .liquid .html .haml .slim .css .scss] }

  def shipped_files(roots, text_extensions, excluded_path)
    roots.flat_map { |root| Dir.glob(Rails.root.join(root, '**', '*')) }
         .reject { |path| File.directory?(path) }
         .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
         .select { |path| text_extensions.include?(File.extname(path)) }
         .grep_v(excluded_path)
  end

  # A comment recording what was removed is documentation, not a connection. Only
  # lines that could become a request are considered.
  def executable_lines(path)
    File.readlines(Rails.root.join(path), chomp: true).each_with_index.reject do |line, _index|
      stripped = line.strip
      stripped.empty? || stripped.start_with?('#', '//', '*', '/*', '<!--')
    end
  end

  it 'ships no Chatwoot host in any executable line' do
    offenders = shipped_files(roots, text_extensions, excluded_path).flat_map do |path|
      executable_lines(path).filter_map do |line, index|
        "#{path}:#{index + 1}: #{line.strip[0, 160]}" if host_pattern.match?(line)
      end
    end

    expect(offenders).to be_empty, <<~MESSAGE
      A Chatwoot host reappeared in shipped code:

      #{offenders.join("\n")}
    MESSAGE
  end

  it 'has no hub client to call' do
    expect(defined?(ChatwootHub)).to be_nil
    expect(defined?(Lla::Hub::EgressPolicy)).to be_nil
  end

  it 'has no version check to schedule' do
    expect(defined?(Internal::CheckNewVersionsJob)).to be_nil
    expect(Redis::Alfred.const_defined?(:LATEST_CHATWOOT_VERSION)).to be(false)
  end

  it 'does not relay push notifications anywhere but the configured providers' do
    expect(Notification::PushNotificationService.instance_methods(false).map(&:to_s))
      .not_to include('send_push_via_chatwoot_hub')
    expect(Notification::PushNotificationService.private_instance_methods(false).map(&:to_s))
      .not_to include('chatwoot_hub_enabled?')
  end

  # The two feeds the dashboard used to fetch on every load. Both are operator
  # configuration now, empty by default, and empty must mean "no request".
  describe 'the browser-side feeds' do
    it 'defaults the changelog and testimonial feeds to empty' do
      # The shipped defaults, not the test database, which is loaded from schema
      # and never seeded.
      defaults = YAML.safe_load(Rails.root.join('config/installation_config.yml').read)
                     .index_by { |entry| entry['name'] }

      %w[CHANGELOG_URL TESTIMONIALS_URL DOCS_URL].each do |key|
        entry = defaults[key]

        expect(entry).not_to be_nil, "#{key} is not an installation setting"
        expect(entry['value'].to_s).to eq(''), "#{key} ships a default of #{entry['value'].inspect}"
      end
    end

    it 'exposes them to the dashboard, so an operator can point them somewhere' do
      expect(DashboardController::GLOBAL_CONFIG_KEYS).to include('CHANGELOG_URL', 'TESTIMONIALS_URL', 'DOCS_URL')
    end
  end
end
