# frozen_string_literal: true

# Ghi chú trên mọi contact thuộc company — giao diện trang company đọc qua
# CompanyAPI#listNotes (MIT companies.js).
class Api::V1::Accounts::Companies::NotesController < Api::V1::Accounts::Companies::BaseController
  def index
    @notes = Note.where(contact_id: @company.contact_ids)
                 .includes(:user)
                 .order(created_at: :desc)
  end
end
