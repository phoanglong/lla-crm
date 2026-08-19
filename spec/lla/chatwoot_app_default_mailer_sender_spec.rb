# frozen_string_literal: true

require 'rails_helper'

# `MAILER_SENDER_EMAIL` unset used to mean `Chatwoot <accounts@chatwoot.com>` — mail
# from a domain the installation does not own, failing SPF and DMARC. The default is
# now derived from the installation's own `FRONTEND_URL`.
#
# Review then ran the derivation against real values and found three ways it produced
# a *wrong* address rather than an obviously broken one. Silent wrongness in a From
# header is worse than a crash: nobody notices until deliverability drops.
RSpec.describe ChatwootApp, '.default_mailer_sender' do
  def sender_for(frontend_url)
    with_modified_env('FRONTEND_URL' => frontend_url) { described_class.default_mailer_sender }
  end

  it 'falls back to localhost when nothing is configured' do
    expect(sender_for(nil)).to eq('no-reply@localhost')
    expect(sender_for('')).to eq('no-reply@localhost')
    expect(sender_for('   ')).to eq('no-reply@localhost')
  end

  it 'uses the configured host, dropping scheme, port, path and userinfo' do
    expect(sender_for('https://crm.example.com')).to eq('no-reply@crm.example.com')
    expect(sender_for('https://crm.example.com:3000/app')).to eq('no-reply@crm.example.com')
    expect(sender_for('http://user:secret@crm.example.com/x?y=1#z')).to eq('no-reply@crm.example.com')
  end

  # The footgun: an operator who thinks of FRONTEND_URL as a hostname writes one.
  # `URI.parse('crm.example.com').host` is nil, so this used to send from localhost
  # and say nothing about it.
  it 'reads a scheme-less value as the hostname it was meant to be' do
    expect(sender_for('crm.example.com')).to eq('no-reply@crm.example.com')
    expect(sender_for('crm.example.com:3000')).to eq('no-reply@crm.example.com')
    expect(sender_for('crm.example.com/app')).to eq('no-reply@crm.example.com')
  end

  # RFC 5321 §4.1.3: an IPv6 literal is `[IPv6:<addr>]`. `[::1]` alone is not one, and
  # a strict MTA is entitled to reject it.
  it 'writes an IPv6 host as an RFC 5321 address literal' do
    expect(sender_for('http://[::1]:3000')).to eq('no-reply@[IPv6:::1]')
    expect(sender_for('http://[2001:db8::1]')).to eq('no-reply@[IPv6:2001:db8::1]')
  end

  it 'downcases the host, so the same installation always sends from one address' do
    expect(sender_for('HTTPS://CRM.EXAMPLE.COM')).to eq('no-reply@crm.example.com')
    expect(sender_for('CRM.Example.Com')).to eq('no-reply@crm.example.com')
  end

  it 'falls back rather than emitting a nonsense host' do
    expect(sender_for('not a url')).to eq('no-reply@localhost')
    expect(sender_for('://bad')).to eq('no-reply@localhost')
    expect(sender_for('http://')).to eq('no-reply@localhost')
  end

  it 'produces an address Mail can parse, for every case above' do
    [
      nil, '', 'crm.example.com', 'https://crm.example.com',
      'https://crm.example.com:3000/app', 'http://[::1]:3000',
      'HTTPS://CRM.EXAMPLE.COM', 'not a url'
    ].each do |value|
      address = sender_for(value)

      expect { Mail::Address.new(address) }.not_to raise_error, "#{value.inspect} produced #{address}"
      expect(Mail::Address.new(address).address).to eq(address)
    end
  end

  # `default from:` is evaluated once when the mailer class loads, so it reflects the
  # environment the process booted with — correct for a deployment, and worth stating
  # so nobody expects a mid-process ENV change to move it.
  it 'is what the mailers default to, resolved at boot' do
    expect(ApplicationMailer.default[:from]).to eq(described_class.default_mailer_sender)
    expect(ConversationReplyMailer.default[:from]).to eq(described_class.default_mailer_sender)
    expect(ApplicationMailer.default[:from]).not_to include('chatwoot.com')
  end

  it 'never resolves to a Chatwoot-operated domain' do
    ['', 'crm.example.com', 'https://crm.example.com', 'http://[::1]:3000'].each do |value|
      expect(sender_for(value)).not_to include('chatwoot.com')
    end
  end
end
