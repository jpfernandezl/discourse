# frozen_string_literal: true

class Poll < ActiveRecord::Base
  # because we want to use the 'type' column and don't want to use STI
  self.inheritance_column = nil

  belongs_to :post

  has_many :poll_options, dependent: :destroy
  has_many :poll_votes, dependent: :delete_all

  validates :type, inclusion: { in: %w(regular multiple number) }
  validates :status, inclusion: { in: %w(open closed) }
  validates :results, inclusion: { in: %w(always vote closed) }

  validates :min, numericality: { allow_nil: true, only_integer: true, greater_than: 0 }
  validates :max, numericality: { allow_nil: true, only_integer: true, greater_than: 0 }
  validates :step, numericality: { allow_nil: true, only_integer: true, greater_than: 0 }

  def open?
    status == "open"
  end

  def closed?
    status == "closed" || (close_at && close_at <= Time.zone.now)
  end

  def public?
    visibility == "public"
  end

  def can_see_results?(user)
    case results
    when "always" then true
    when "closed" then closed?
    when "vote"   then closed? || has_voted?(user)
    end
  end

  def has_voted?(user)
    return false unless user
    poll_votes.any? { |vote| vote.user_id == user.id }
  end

  def can_see_voters?(user)
    public? && can_see_results?(user)
  end

  def number?
    type == "number"
  end

  def multiple?
    type == "multiple"
  end
end
