require 'rails_helper'

describe DiscoursePoll::PollsUpdater do

  def update(post, polls)
    DiscoursePoll::PollsUpdater.update(post, polls)
  end

  let(:user) { Fabricate(:user) }

  let(:post) {
    Fabricate(:post, raw: <<~RAW)
      [poll]
      * 1
      * 2
      [/poll]
    RAW
  }

  let(:post_with_3_options) {
    Fabricate(:post, raw: <<~RAW)
      [poll]
      - a
      - b
      - c
      [/poll]
    RAW
  }

  let(:polls) {
    DiscoursePoll::PollsValidator.new(post).validate_polls
  }

  let(:polls_with_3_options) {
    DiscoursePoll::PollsValidator.new(post_with_3_options).validate_polls
  }

  describe "update" do

    describe "within edit window" do

      describe "when post has no polls" do

        it "creates the poll" do
          post = Fabricate(:post)

          message = MessageBus.track_publish do
            update(post, polls)
          end.first

          poll = Poll.find_by(post: post)

          expect(poll).to be
          expect(poll.poll_options.size).to eq(2)

          expect(message.data[:post_id]).to eq(post.id)
          expect(message.data[:polls][0][:name]).to eq(poll.name)
        end

      end

      describe "when post has a poll" do

        it "updates the poll & delete votes" do
          expect {
            DiscoursePoll::Poll.vote(post.id, "poll", [polls["poll"]["options"][0]["id"]], user)
          }.to change { PollVote.count }.by(1)

          message = MessageBus.track_publish do
            update(post, polls_with_3_options)
          end.first

          poll = Poll.find_by(post: post)

          expect(poll).to be
          expect(poll.poll_options.size).to eq(3)
          expect(poll.poll_votes.size).to eq(0)

          expect(message.data[:post_id]).to eq(post.id)
          expect(message.data[:polls][0][:name]).to eq(poll.name)
        end

        it "deletes the poll" do
          update(post, {})
          expect(Poll.where(post: post).exists?).to eq(false)
        end

      end

    end

    describe "outside the edit window" do

      it "throws an error when there are votes" do
        edit_window = SiteSetting.poll_edit_window_mins

        expect {
          DiscoursePoll::Poll.vote(post.id, "poll", [polls["poll"]["options"][0]["id"]], user)
        }.to change { PollVote.count }.by(1)

        freeze_time (edit_window + 1).minutes.from_now

        update(post, polls_with_3_options)

        expect(post.errors[:base]).to include(
          I18n.t(
            "poll.edit_window_expired.cannot_edit_poll_with_votes",
            minutes: edit_window
          )
        )
      end

    end

  end

end
