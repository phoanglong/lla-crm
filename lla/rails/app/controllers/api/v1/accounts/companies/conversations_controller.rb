# frozen_string_literal: true

# Hội thoại của mọi contact thuộc company — giao diện trang company đọc qua
# CompanyAPI#listConversations (MIT companies.js).
class Api::V1::Accounts::Companies::ConversationsController < Api::V1::Accounts::Companies::BaseController
  RESULTS_PER_PAGE = 25

  def index
    @conversations = Current.account.conversations
                            .where(contact_id: @company.contact_ids)
                            .includes(:assignee, :contact, :inbox, :taggings)
                            .order(last_activity_at: :desc)
                            .page(params[:page]).per(RESULTS_PER_PAGE)
  end
end
