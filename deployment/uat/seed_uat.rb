# frozen_string_literal: true

# Synthetic seed for the isolated LLA CRM UAT stack.
#
#   docker compose -f deployment/uat/compose.lla-uat.yaml exec rails \
#     bundle exec rails runner deployment/uat/seed_uat.rb
#
# Everything created here is invented. There is no customer name, no resolvable
# email domain (`.invalid` is reserved by RFC 2606), no real phone number, no
# imported production message and no provider credential. It is idempotent, so a
# re-run after a redeploy does not multiply tenants.
#
# The administrator password comes from the environment rather than from this file,
# so a synthetic credential does not end up in the repository either. It has to
# satisfy the product's password policy — at least one uppercase letter and one
# special character.
module LlaUatSeed
  ACCOUNT_NAME = 'LLA UAT Tenant'
  PORTAL_SLUG = 'uat-portal'
  INBOX_NAME = 'UAT API Inbox'
  CONTACT_NAME = 'UAT Synthetic Contact'

  module_function

  def admin_email
    ENV.fetch('UAT_ADMIN_EMAIL', 'uat.admin@lla-uat.invalid')
  end

  def admin_password
    ENV.fetch('UAT_ADMIN_PASSWORD') do
      abort('UAT_ADMIN_PASSWORD must be set; refusing to seed a well-known password')
    end
  end

  def administrator(account)
    user = User.from_email(admin_email)
    user ||= User.create!(name: 'UAT Administrator', email: admin_email,
                          password: admin_password, password_confirmation: admin_password)
    user.update!(confirmed_at: Time.current) if user.confirmed_at.blank?
    AccountUser.find_or_create_by!(account_id: account.id, user_id: user.id) do |membership|
      membership.role = :administrator
    end
    user
  end

  def api_inbox(account, user)
    inbox = account.inboxes.find_by(name: INBOX_NAME)
    unless inbox
      channel = Channel::Api.create!(account: account, webhook_url: nil)
      inbox = Inbox.create!(account: account, channel: channel, name: INBOX_NAME)
    end
    InboxMember.find_or_create_by!(inbox_id: inbox.id, user_id: user.id)
    inbox
  end

  def conversation(account, inbox, user)
    contact = account.contacts.find_or_create_by!(email: 'uat.contact@lla-uat.invalid') do |record|
      record.name = CONTACT_NAME
    end
    contact_inbox = ContactInbox.find_or_create_by!(contact_id: contact.id, inbox_id: inbox.id) do |record|
      record.source_id = "uat-synthetic-#{contact.id}"
    end
    record = Conversation.find_or_create_by!(account_id: account.id, inbox_id: inbox.id,
                                             contact_id: contact.id, contact_inbox_id: contact_inbox.id)
    seed_messages(record, account, inbox, user)
    [contact, record]
  end

  def seed_messages(record, account, inbox, user)
    return if record.messages.any?

    record.messages.create!(account_id: account.id, inbox_id: inbox.id,
                            message_type: :incoming, content: 'Xin chào, đây là tin nhắn UAT tổng hợp.')
    record.messages.create!(account_id: account.id, inbox_id: inbox.id, sender: user,
                            message_type: :outgoing, content: 'Đây là câu trả lời UAT tổng hợp.')
  end

  def help_center(account, user)
    portal = account.portals.find_or_create_by!(slug: PORTAL_SLUG) do |record|
      record.name = 'UAT Portal'
    end
    portal.update!(config: { allowed_locales: %w[en], default_locale: 'en' }) if portal.config.blank?
    category = portal.categories.find_or_create_by!(slug: 'uat-getting-started', locale: 'en') do |record|
      record.name = 'Getting started'
      record.account_id = account.id
    end
    [portal, article(portal, category, account, user)]
  end

  def article(portal, category, account, user)
    record = portal.articles.find_or_create_by!(slug: 'uat-first-article') do |draft|
      draft.account_id = account.id
      draft.category_id = category.id
      draft.author_id = user.id
      draft.title = 'UAT first article'
      draft.content = 'This article exists so the UAT help center has something real to render.'
    end
    record.update!(status: :published) unless record.published?
    record
  end
end

abort('refusing to seed a production-mode database without LLA_UAT_SEED_CONFIRM=yes') if Rails.env.production? && ENV['LLA_UAT_SEED_CONFIRM'] != 'yes'

ActiveRecord::Base.transaction do
  account = Account.find_or_create_by!(name: LlaUatSeed::ACCOUNT_NAME)
  user = LlaUatSeed.administrator(account)
  inbox = LlaUatSeed.api_inbox(account, user)
  contact, conversation = LlaUatSeed.conversation(account, inbox, user)
  portal, article = LlaUatSeed.help_center(account, user)

  puts({ account_id: account.id, user_id: user.id, inbox_id: inbox.id, contact_id: contact.id,
         conversation_id: conversation.id, portal_id: portal.id, article_id: article.id }.to_json)
end

# `db:chatwoot_prepare` sets an installation-onboarding flag whenever it finds no
# users, and `DashboardController` then redirects every /app route to
# /installation/onboarding. Seeding the administrator here *is* that onboarding, so
# the flag has to go or the stack answers the wizard to every login.
Redis::Alfred.delete(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)
puts 'installation onboarding flag cleared'
