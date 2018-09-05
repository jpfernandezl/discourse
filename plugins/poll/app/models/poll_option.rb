class PollOption < ActiveRecord::Base
  belongs_to :poll
  has_many :poll_votes, dependent: :delete_all

  default_scope { order(created_at: :asc) }
end
