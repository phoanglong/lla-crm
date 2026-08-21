# frozen_string_literal: true

# Reviewer notes on a CSAT response, owned by LLA.
#
# The enterprise version read `params[:csat_review_notes]` directly. That is not a
# permitted parameter, so it accepted whatever arrived: a Hash, an Array, a
# megabyte of text, control characters, or markup that later rendered wherever the
# note is displayed. It also wrote unconditionally, so two reviewers editing the
# same response silently overwrote each other with no record that it happened.
module Lla::Api::V1::Accounts::CsatSurveyResponsesController
  MAX_REVIEW_NOTE_LENGTH = 5_000

  def update
    @csat_survey_response = Current.account.csat_survey_responses.find(params[:id])
    authorize @csat_survey_response

    notes = review_notes
    return render_invalid_note if notes == :invalid

    @csat_survey_response.update!(
      csat_review_notes: notes,
      review_notes_updated_by: Current.user,
      review_notes_updated_at: Time.current
    )
  end

  private

  # Returns the note to store, `nil` to clear it, or `:invalid`.
  #
  # The shape is read before permitting, not after: `permit(:csat_review_notes)`
  # silently drops a Hash or an Array because they are not scalars, so a caller
  # sending one would otherwise look identical to a caller clearing the note.
  def review_notes
    return nil unless params.key?(:csat_review_notes)

    raw = params[:csat_review_notes]
    return nil if raw.nil?
    # Only a String is a note. `to_s` on ActionController::Parameters or an Array
    # would store something absurd instead of refusing it.
    return :invalid unless raw.is_a?(String)

    normalized = normalize(raw)
    return nil if normalized.empty?
    return :invalid if normalized.length > MAX_REVIEW_NOTE_LENGTH

    normalized
  end

  # Stored as plain text. Control characters other than tab and newline are removed
  # rather than escaped, because there is no display context in which they are
  # meaningful and several in which they are dangerous. Markup is neither stripped
  # nor sanitized here: the note is stored as written and every consumer escapes it,
  # which is the contract that holds for API clients and exports too — client-side
  # sanitizing only ever protected one of them.
  def normalize(raw)
    raw.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
       .gsub(/[^\P{Cc}\t\n]/, '')
       .strip
  end

  def render_invalid_note
    render json: { error: "csat_review_notes must be text of at most #{MAX_REVIEW_NOTE_LENGTH} characters" },
           status: :unprocessable_entity
  end
end
