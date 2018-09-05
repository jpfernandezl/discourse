# frozen_string_literal: true

module DiscoursePoll
  class PollsUpdater

    UPDATABLE_POLL_ATTRIBUTES ||= %i{close_at max min results status step type visibility}
    BREAKING_POLL_ATTRIBUTES  ||= %i{max min step type visibility}

    def self.update(post, polls)
      has_changed = false
      edit_window = SiteSetting.poll_edit_window_mins

      old_poll_names = ::Poll.where(post: post).pluck(:name)
      new_poll_names = polls.keys

      deleted_poll_names = old_poll_names - new_poll_names
      created_poll_names = new_poll_names - old_poll_names

      # delete polls
      if deleted_poll_names.present?
        ::Poll.where(post: post, name: deleted_poll_names).destroy_all
      end

      # create polls
      if created_poll_names.present?
        has_changed = true
        polls.slice(*created_poll_names).values.each do |poll|
          Poll.create!(post.id, poll)
        end
      end

      # update polls
      ::Poll.includes(:poll_votes, :poll_options).where(post: post).find_each do |old_poll|
        new_poll = polls[old_poll.name]
        new_poll_options = new_poll["options"]

        attributes = new_poll.slice(UPDATABLE_POLL_ATTRIBUTES)
        attributes["visibility"] = new_poll["public"] == "true" ? "public" : "private"
        attributes["close_at"] = Time.zone.parse(new_poll["close"]) rescue nil
        poll = ::Poll.new(attributes)

        if is_different?(old_poll, poll, new_poll_options)
          if old_poll.created_at < edit_window.minutes.ago && old_poll.poll_votes.size > 0
            post.errors.add(:base, I18n.t(
              "poll.edit_window_expired.cannot_edit_poll_with_votes",
              minutes: edit_window
            ))
            return
          else
            # update poll
            UPDATABLE_POLL_ATTRIBUTES.each do |attr|
              old_poll.send("#{attr}=", poll.send(attr))
            end
            old_poll.save!

            # destroy existing options & votes
            ::PollOption.where(poll: old_poll).destroy_all

            # create new options
            new_poll_options.each do |option|
              ::PollOption.create!(
                poll: old_poll,
                digest: option["id"],
                html: option["html"].strip,
              )
            end

            has_changed = true
          end
        end
      end

      if has_changed
        polls = ::Poll.includes(poll_options: :poll_votes).where(post: post)
        polls = ActiveModel::ArraySerializer.new(polls, each_serializer: PollSerializer, root: false).as_json
        MessageBus.publish("/polls/#{post.topic_id}", post_id: post.id, polls: polls)
      end
    end

    private

    def self.is_different?(old_poll, new_poll, new_options)
      # check poll attributes
      BREAKING_POLL_ATTRIBUTES.each do |attr|
        return true if old_poll.send(attr) != new_poll.send(attr)
      end

      # check poll options
      return true if old_poll.poll_options.map { |o| o.digest }.sort != new_options.map { |o| o["id"] }.sort

      # it's the same!
      false
    end

  end
end
