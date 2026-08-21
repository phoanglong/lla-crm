# frozen_string_literal: true

class Integrations::Facebook::MessageCreator
  attr_reader :response, :account_id

  # `account_id` được truyền vào khi sự kiện tới qua webhook riêng của tenant: lúc đó danh
  # tính tenant đã chắc chắn từ đường dẫn, nên không việc gì phải quét mọi tài khoản có
  # cùng `page_id`.
  def initialize(response, account_id: nil)
    @response = response
    @account_id = account_id
  end

  def perform
    # begin
    if agent_message_via_echo?
      create_agent_message
    else
      create_contact_message
    end
    # rescue => e
    # ChatwootExceptionTracker.new(e).capture_exception
    # end
  end

  private

  def agent_message_via_echo?
    # TODO : check and remove send_from_chatwoot_app if not working
    response.echo? && !response.sent_from_chatwoot_app?
    # this means that it is an agent message from page, but not sent from chatwoot.
    # User can send from fb page directly on mobile / web messenger, so this case should be handled as agent message
  end

  def create_agent_message
    pages_for(response.sender_id).each do |page|
      mb = Messages::Facebook::MessageBuilder.new(response, page.inbox, outgoing_echo: true)
      mb.perform
    end
  end

  def create_contact_message
    pages_for(response.recipient_id).each do |page|
      mb = Messages::Facebook::MessageBuilder.new(response, page.inbox)
      mb.perform
    end
  end

  def pages_for(page_id)
    scope = Channel::FacebookPage.where(page_id: page_id)
    account_id.present? ? scope.where(account_id: account_id) : scope
  end
end
