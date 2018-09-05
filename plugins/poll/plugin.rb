# frozen_string_literal: true

# name: poll
# about: Official poll plugin for Discourse
# version: 1.0
# authors: Vikhyat Korrapati (vikhyat), Régis Hanol (zogstrip)
# url: https://github.com/discourse/discourse/tree/master/plugins/poll

register_asset "stylesheets/common/poll.scss"
register_asset "stylesheets/common/poll-ui-builder.scss"
register_asset "stylesheets/desktop/poll.scss", :desktop
register_asset "stylesheets/mobile/poll.scss", :mobile

enabled_site_setting :poll_enabled
hide_plugin if self.respond_to?(:hide_plugin)

PLUGIN_NAME ||= "discourse_poll"
DATA_PREFIX ||= "data-poll-"

after_initialize do

  require File.expand_path("../jobs/regular/close_poll", __FILE__)

  module ::DiscoursePoll
    DEFAULT_POLL_NAME ||= "poll"

    autoload :PostValidator,  "#{Rails.root}/plugins/poll/lib/post_validator"
    autoload :PollsValidator, "#{Rails.root}/plugins/poll/lib/polls_validator"
    autoload :PollsUpdater,   "#{Rails.root}/plugins/poll/lib/polls_updater"

    require_relative "app/models/poll_vote"
    require_relative "app/models/poll_option"
    require_relative "app/models/poll"

    require_relative "app/serializers/poll_serializer"
    require_relative "app/serializers/poll_option_serializer"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscoursePoll
    end
  end

  class DiscoursePoll::Poll
    class << self

      def vote(post_id, poll_name, options, user)
        Poll.transaction do
          post = Post.find_by(id: post_id)

          # post must not be deleted
          if post.nil? || post.trashed?
            raise StandardError.new I18n.t("poll.post_is_deleted")
          end

          # topic must not be archived
          if post.topic&.archived
            raise StandardError.new I18n.t("poll.topic_must_be_open_to_vote")
          end

          # user must be allowed to post in topic
          if !Guardian.new(user).can_create_post?(post.topic)
            raise StandardError.new I18n.t("poll.user_cant_post_in_topic")
          end

          poll = Poll.includes(poll_options: :poll_votes).find_by(post_id: post_id, name: poll_name)

          raise StandardError.new I18n.t("poll.no_poll_with_this_name", name: poll_name) unless poll
          raise StandardError.new I18n.t("poll.poll_must_be_open_to_vote") if poll.closed?

          # remove options that aren't available in the poll
          available_options = poll.poll_options.map { |option| option.digest }.to_set
          options.select! { |o| available_options.include?(o) }

          raise StandardError.new I18n.t("poll.requires_at_least_1_valid_option") if options.empty?

          old_option_ids = poll
            .poll_options
            .select { |o| o.poll_votes.any? { |v| v.user_id == user.id } }
            .map { |o| o.id }

          new_option_ids = poll
            .poll_options
            .select { |o| options.include?(o.digest) }
            .map { |o| o.id }

          # remove non-selected votes
          PollVote
            .where(poll: poll, user: user)
            .where.not(poll_option_id: new_option_ids)
            .delete_all

          # create missing votes
          (new_option_ids - old_option_ids).each do |option_id|
            PollVote.create!(poll: poll, user: user, poll_option_id: option_id)
          end

          poll.reload

          serialized_poll = PollSerializer.new(poll, root: false).as_json
          payload = { post_id: post_id, polls: [serialized_poll] }

          MessageBus.publish("/polls/#{post.topic_id}", payload)

          [serialized_poll, options]
        end
      end

      def toggle_status(post_id, poll_name, status, user)
        Poll.transaction do
          post = Post.find_by(id: post_id)

          # post must not be deleted
          if post.nil? || post.trashed?
            raise StandardError.new I18n.t("poll.post_is_deleted")
          end

          # topic must not be archived
          if post.topic&.archived
            raise StandardError.new I18n.t("poll.topic_must_be_open_to_toggle_status")
          end

          # either staff member or OP
          unless post.user_id == user&.id || user&.staff?
            raise StandardError.new I18n.t("poll.only_staff_or_op_can_toggle_status")
          end

          poll = Poll.find_by(post_id: post_id, name: poll_name)

          raise StandardError.new I18n.t("poll.no_poll_with_this_name", name: poll_name) unless poll

          poll.status = status
          poll.save!

          serialized_poll = PollSerializer.new(poll, root: false).as_json
          payload = { post_id: post_id, polls: [serialized_poll] }

          MessageBus.publish("/polls/#{post.topic_id}", payload)

          serialized_poll
        end
      end

      def voters(post_id, poll_name, user, opts = {})
        post = Post.find_by(id: post_id)
        raise Discourse::InvalidParameters.new("post_id is invalid") unless post

        poll = Poll.find_by(post_id: post_id, name: poll_name)
        raise Discourse::InvalidParameters.new("poll_name is invalid") unless poll&.can_see_voters?(user)

        limit = (opts["limit"] || 25).to_i
        limit = 0  if limit < 0
        limit = 50 if limit > 50

        page = (opts["page"] || 1).to_i
        page = 1 if page < 1

        offset = (page - 1) * limit

        option_digest = opts["option_id"].to_s

        if poll.number?
          user_ids = PollVote
            .where(poll: poll)
            .group(:user_id)
            .order("MIN(created_at)")
            .offset(offset)
            .limit(limit)
            .pluck(:user_id)

          result = User.where(id: user_ids).map { |u| UserNameSerializer.new(u).serializable_hash }
        elsif option_digest.present?
          poll_option = PollOption.find_by(poll: poll, digest: option_digest)

          raise Discourse::InvalidParameters.new("option_id is invalid") unless poll_option

          user_ids = PollVote
            .where(poll: poll, poll_option: poll_option)
            .group(:user_id)
            .order("MIN(created_at)")
            .offset(offset)
            .limit(limit)
            .pluck(:user_id)

          user_hashes = User.where(id: user_ids).map { |u| UserNameSerializer.new(u).serializable_hash }

          result = { option_digest => user_hashes }
        else
          votes = DB.query <<~SQL
            SELECT digest, user_id
              FROM (
                SELECT digest
                     , user_id
                     , ROW_NUMBER() OVER (PARTITION BY poll_option_id ORDER BY pv.created_at) AS row
                  FROM poll_votes pv
                  JOIN poll_options po ON pv.poll_option_id = po.id
                 WHERE pv.poll_id = #{poll.id}
                   AND po.poll_id = #{poll.id}
              ) v
              WHERE row BETWEEN #{offset} AND #{offset + limit}
          SQL

          user_ids = votes.map { |v| v.user_id }.to_set

          user_hashes = User
            .where(id: user_ids)
            .map { |u| [u.id, UserNameSerializer.new(u).serializable_hash] }
            .to_h

          result = {}
          votes.each do |v|
            result[v.digest] ||= []
            result[v.digest] << user_hashes[v.user_id]
          end
        end

        result
      end

      def schedule_jobs(post)
        Poll.where(post: post).find_each do |poll|
          Jobs.cancel_scheduled_job(:close_poll, poll_id: poll.id)

          if poll.open? && poll.close_at && poll.close_at > Time.zone.now
            Jobs.enqueue_at(poll.close_at, :close_poll, poll_id: poll.id)
          end
        end
      end

      def create!(post_id, poll)
        created_poll = Poll.create!(
          post_id: post_id,
          name: poll["name"].presence || "poll",
          close_at: (Time.zone.parse(poll["close"]) rescue nil),
          type: poll["type"].presence || "regular",
          status: poll["status"].presence || "open",
          visibility: poll["public"] == "true" ? "public" : "private",
          results: poll["results"].presence || "always",
          min: poll["min"],
          max: poll["max"],
          step: poll["step"]
        )

        poll["options"].each do |option|
          PollOption.create!(
            poll: created_poll,
            digest: option["id"].presence,
            html: option["html"].presence.strip
          )
        end
      end

      def extract(raw, topic_id, user_id = nil)
        # TODO: we should fix the callback mess so that the cooked version is available
        # in the validators instead of cooking twice
        cooked = PrettyText.cook(raw, topic_id: topic_id, user_id: user_id)

        Nokogiri::HTML(cooked).css("div.poll").map do |p|
          poll = { "options" => [], "name" => DiscoursePoll::DEFAULT_POLL_NAME }

          # attributes
          p.attributes.values.each do |attribute|
            if attribute.name.start_with?(DATA_PREFIX)
              poll[attribute.name[DATA_PREFIX.length..-1]] = CGI.escapeHTML(attribute.value || "")
            end
          end

          # options
          p.css("li[#{DATA_PREFIX}option-id]").each do |o|
            option_id = o.attributes[DATA_PREFIX + "option-id"].value.to_s
            poll["options"] << { "id" => option_id, "html" => o.inner_html.strip }
          end

          poll
        end
      end
    end
  end

  require_dependency "application_controller"

  class DiscoursePoll::PollsController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    before_action :ensure_logged_in, except: [:voters]

    def vote
      post_id   = params.require(:post_id)
      poll_name = params.require(:poll_name)
      options   = params.require(:options)

      begin
        poll, options = DiscoursePoll::Poll.vote(post_id, poll_name, options, current_user)
        render json: { poll: poll, vote: options }
      rescue StandardError => e
        render_json_error e.message
      end
    end

    def toggle_status
      post_id   = params.require(:post_id)
      poll_name = params.require(:poll_name)
      status    = params.require(:status)

      begin
        poll = DiscoursePoll::Poll.toggle_status(post_id, poll_name, status, current_user)
        render json: { poll: poll }
      rescue StandardError => e
        render_json_error e.message
      end
    end

    def voters
      post_id   = params.require(:post_id)
      poll_name = params.require(:poll_name)

      opts = params.permit(:limit, :page, :option_id)

      begin
        render json: { voters: DiscoursePoll::Poll.voters(post_id, poll_name, current_user, opts) }
      rescue StandardError => e
        render_json_error e.message
      end
    end
  end

  DiscoursePoll::Engine.routes.draw do
    put "/vote" => "polls#vote"
    put "/toggle_status" => "polls#toggle_status"
    get "/voters" => 'polls#voters'
  end

  Discourse::Application.routes.append do
    mount ::DiscoursePoll::Engine, at: "/polls"
  end

  Post.class_eval do
    attr_accessor :extracted_polls

    has_many :polls, dependent: :delete_all

    after_save do
      next if self.extracted_polls.blank? || !self.extracted_polls.is_a?(Hash)

      post = self
      polls = self.extracted_polls

      Poll.transaction do
        polls.values.each do |poll|
          DiscoursePoll::Poll.create!(post.id, poll)
        end
      end
    end
  end

  validate(:post, :validate_polls) do |force = nil|
    return unless self.raw_changed? || force

    validator = DiscoursePoll::PollsValidator.new(self)
    return unless (polls = validator.validate_polls)

    if polls.present?
      validator = DiscoursePoll::PostValidator.new(self)
      return unless validator.validate_post
    end

    # are we updating a post?
    if self.id.present?
      Poll.transaction do
        DiscoursePoll::PollsUpdater.update(self, polls)
      end
    else
      self.extracted_polls = polls
    end

    true
  end

  NewPostManager.add_handler(1) do |manager|
    post = Post.new(raw: manager.args[:raw])

    if !DiscoursePoll::PollsValidator.new(post).validate_polls
      result = NewPostResult.new(:poll, false)

      post.errors.full_messages.each do |message|
        result.errors[:base] << message
      end

      result
    else
      manager.args["is_poll"] = true
      nil
    end
  end

  on(:approved_post) do |queued_post, created_post|
    if queued_post.post_options["is_poll"]
      created_post.validate_polls(true)
    end
  end

  on(:reduce_cooked) do |fragment, post|
    if post.nil? || post.trashed?
      fragment.css(".poll, [data-poll-name]").each(&:remove)
    else
      post_url = post.full_url
      fragment.css(".poll, [data-poll-name]").each do |poll|
        poll.replace "<p><a href='#{post_url}'>#{I18n.t("poll.email.link_to_poll")}</a></p>"
      end
    end
  end

  on(:post_created) do |post|
    DiscoursePoll::Poll.schedule_jobs(post)

    unless post.is_first_post?
      polls = ActiveModel::ArraySerializer.new(post.polls, each_serializer: PollSerializer, root: false).as_json
      MessageBus.publish("/polls/#{post.topic_id}", post_id: post.id, polls: polls)
    end
  end

  on(:merging_users) do |source_user, target_user|
    PollVote.where(user: source_user).update_all(user: target_user)
  end

  on(:user_destroyed) do |user|
    PollVote.where(user: user).delete_all
  end

  add_to_class(:topic_view, :polls) do
    @polls ||= begin
      polls = {}

      Poll
        .includes(poll_options: :poll_votes, poll_votes: :poll_option)
        .where(post_id: filtered_post_ids)
        .each do |p|
          polls[p.post_id] ||= []
          polls[p.post_id] << p
        end

      polls
    end
  end

  add_to_serializer(:post, :preloaded_polls, false) do
    @preloaded_polls ||= if @topic_view.present?
      @topic_view.polls[object.id]
    else
      Poll.includes(poll_options: :poll_votes).where(post: object)
    end
  end

  add_to_serializer(:post, :include_preloaded_polls?) do
    false
  end

  add_to_serializer(:post, :polls, false) do
    preloaded_polls.map { |p| PollSerializer.new(p, root: false) }
  end

  add_to_serializer(:post, :include_polls?) do
    preloaded_polls.present?
  end

  add_to_serializer(:post, :polls_votes, false) do
    preloaded_polls.map do |poll|
      [
        poll.name,
        poll.poll_votes
          .select { |v| v.user_id == scope.user.id }
          .map { |v| v.poll_option.digest }
      ]
    end.to_h
  end

  add_to_serializer(:post, :include_polls_votes?) do
    scope.user&.id.present? &&
    preloaded_polls.present? &&
    preloaded_polls.any? { |p| p.has_voted?(scope.user) }
  end
end
