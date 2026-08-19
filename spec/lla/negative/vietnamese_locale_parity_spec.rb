# frozen_string_literal: true

require 'rails_helper'

# This is a product for the Vietnamese market, so Vietnamese is not one locale among
# fifty-seven: it is the one that has to keep up with the English source.
#
# Review found `calls.json` present only in `en/` — the whole voice-call surface fell
# back to English in every language. Nothing catches that today, because a missing
# translation is invisible: vue-i18n falls back to `en` and the screen still renders.
#
# So this file makes the debt measurable and stops it growing. It does not demand a
# complete translation; it demands that the gap only ever shrinks.
RSpec.describe 'Vietnamese locale parity' do # rubocop:disable RSpec/DescribeClass
  # The ratchet. Measured on the tree that introduced this file. It may go down and
  # must never go up: adding an English key without a Vietnamese one fails here.
  let(:max_missing_keys) { 115 }
  let(:en_dir) { Rails.root.join('app/javascript/dashboard/i18n/locale/en') }
  let(:vi_dir) { Rails.root.join('app/javascript/dashboard/i18n/locale/vi') }
  let(:english) { messages_in(en_dir) }
  let(:vietnamese) { messages_in(vi_dir) }

  def flatten_messages(value, prefix = '')
    case value
    when Hash
      value.flat_map { |key, nested| flatten_messages(nested, prefix.empty? ? key : "#{prefix}.#{key}") }
    when String
      [[prefix, value]]
    else
      []
    end
  end

  def messages_in(dir)
    Dir.glob(dir.join('*.json')).each_with_object({}) do |path, acc|
      file = File.basename(path)
      flatten_messages(JSON.parse(File.read(path))).each { |key, value| acc["#{file}:#{key}"] = value }
    end
  end

  it 'has a Vietnamese file for every English one' do
    en_files = Dir.glob(en_dir.join('*.json')).map { |p| File.basename(p) }.sort
    vi_files = Dir.glob(vi_dir.join('*.json')).map { |p| File.basename(p) }.sort

    expect(en_files - vi_files).to be_empty, <<~MESSAGE
      These English locale files have no Vietnamese counterpart, so the surfaces they
      cover render in English for a Vietnamese user:

      #{(en_files - vi_files).join("\n")}
    MESSAGE
  end

  # A translation file nothing imports is a translation nobody sees. The rule is
  # "vi wires whatever en wires" rather than "vi wires every file on disk", because
  # upstream leaves genuinely dead files around — `webhooks.json` is one, unwired in
  # both locales and referenced by nothing.
  #
  # This caught three: `snooze`, `contentTemplates` and `yearInReview` were translated
  # into Vietnamese and then never loaded.
  it 'wires every module in the Vietnamese index that the English index wires' do
    english_index = File.read(en_dir.join('index.js'))
    vietnamese_index = File.read(vi_dir.join('index.js'))
    modules = english_index.scan(%r{import (\w+) from './(\w+)\.json';})

    unwired = modules.reject do |name, file|
      vietnamese_index.include?("import #{name} from './#{file}.json';") &&
        vietnamese_index.include?("...#{name},")
    end

    expect(unwired).to be_empty, <<~MESSAGE
      Translated but never loaded — present in en/index.js, absent from vi/index.js:

      #{unwired.map(&:last).join("\n")}
    MESSAGE
  end

  it 'does not grow the set of untranslated keys' do
    missing = english.keys - vietnamese.keys

    expect(missing.size).to be <= max_missing_keys, <<~MESSAGE
      Vietnamese is missing #{missing.size} keys, above the recorded ceiling of
      #{max_missing_keys}. Translate the new keys, or lower the ceiling if you have
      translated some — it must never be raised.

      #{missing.first(40).join("\n")}
    MESSAGE
  end

  it 'keeps the ceiling honest, so a fixed gap cannot be silently re-opened' do
    missing = english.keys - vietnamese.keys

    expect(missing.size).to eq(max_missing_keys), <<~MESSAGE
      The gap is now #{missing.size}, not #{max_missing_keys}. If you translated
      something, lower max_missing_keys to #{missing.size} in this file so the ratchet
      holds the new position.
    MESSAGE
  end

  # The primary navigation: what a Vietnamese user reads on every screen. Product
  # names stay as they are — SMS, WhatsApp, CSAT, SLA, Captain, Beta, Macro — so the
  # check is that the *label* differs from English, not that no English word appears.
  it 'translates the navigation a user sees on every screen' do
    labels = %w[
      settings.json:SIDEBAR.CALLS
      settings.json:SIDEBAR.INBOX
      settings.json:SIDEBAR.COMPANIES
      settings.json:SIDEBAR.AUDIT_LOGS
      settings.json:SIDEBAR.SECURITY
      settings.json:SIDEBAR.HELP_CENTER.TITLE
      settings.json:SIDEBAR_ITEMS.PROFILE_SETTINGS
      settings.json:SIDEBAR_ITEMS.LOGOUT
    ]

    untranslated = labels.select { |key| vietnamese[key].nil? || vietnamese[key] == english[key] }

    expect(untranslated).to be_empty, "still English in the navigation: #{untranslated.join(', ')}"
  end

  # The voice-call surface, the one review found. Named on its own so a regression
  # says which surface went back to English.
  it 'translates the whole voice-call surface' do
    call_keys = english.keys.select { |key| key.start_with?('calls.json:') }

    expect(call_keys).not_to be_empty
    expect(call_keys - vietnamese.keys).to be_empty
    still_english = call_keys.select { |key| vietnamese[key] == english[key] }
    expect(still_english).to be_empty, "left in English: #{still_english.join(', ')}"
  end

  it 'is valid JSON in every Vietnamese file' do
    invalid = Dir.glob(vi_dir.join('*.json')).filter_map do |path|
      JSON.parse(File.read(path))
      nil
    rescue JSON::ParserError => e
      "#{File.basename(path)}: #{e.message}"
    end

    expect(invalid).to be_empty
  end
end
