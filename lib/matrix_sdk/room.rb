require 'matrix_sdk/extensions'

module MatrixSdk
  class Room
    attr_accessor :event_history_limit, :prev_batch
    attr_reader :id, :client, :name, :topic, :canonical_alias, :aliases, :join_rule, :guest_access, :members, :events

    events :event, :state_event, :ephemeral_event

    def initialize(client, room_id, data = {})
      @client = client
      @id = room_id

      @name = nil
      @topic = nil
      @canonical_alias = nil
      @aliases = nil
      @join_rule = nil
      @guest_access = nil
      @members = nil
      @events = []
      @event_history_limit = 10

      @prev_batch = nil

      data.each do |k, v|
        instance_variable_set("@#{k}", v) if instance_variable_defined? "@#{k}"
      end
    end

    #
    # State readers
    #

    def display_name
      return name if name
      return canonical_alias if canonical_alias

      members = get_joined_members
                .reject { |m| m.user_id == client.user_id }
                .map(&:get_display_name)

      return members.first if members.one?
      return "#{members.first} and #{members.last}" if members.count == 2
      return "#{members.first} and #{members.count - 1} others" if members.count > 2

      'Empty Room'
    end

    def joined_members
      return members if members

      client.api.get_room_members(id)[:chunk].each do |chunk|
        next unless chunk [:content][:membership] == 'join'
        ensure_member(User.new(client, chunk[:state_key], display_name: chunk[:content].fetch(:displayname)))
      end
      members
    end

    def guest_access?
      guest_access == :can_join
    end

    def invite_only?
      join_rule == :invite
    end

    #
    # Message handling
    #

    def send_text(text)
      client.api.send_message(id, text)
    end

    def send_html(html, body = nil, msg_type = 'm.text')
      content = {
        body: body ? body : html.gsub(/<\/?[^>]*>/, ''),
        msgtype: msg_type,
        format: 'org.matrix.custom.html',
        formatted_body: html
      }

      client.api.send_message_event(id, 'm.room.message', content)
    end

    def send_emote(text)
      client.api.send_emote(id, text)
    end

    def send_file(url, name, file_info = {})
      client.api.send_content(id, url, name, 'm.file', extra_information: file_info)
    end

    def send_notice(text)
      client.api.send_notice(id, text)
    end

    def send_image(url, name, image_info = {})
      client.api.send_content(id, url, name, 'm.image', extra_information: image_info)
    end

    def send_location(geo_uri, name, thumbnail_url = nil, thumbnail_info = {})
      client.api.send_location(id, geo_uri, name, thumbnail_url: thumbnail_url, thumbnail_info: thumbnail_info)
    end

    def send_video(url, name, video_info = {})
      client.api.send_content(id, url, name, 'm.video', extra_information: video_info)
    end

    def send_audio(url, name, audio_info = {})
      client.api.send_content(id, url, name, 'm.audio', extra_information: audio_info)
    end

    def redact_message(event_id, reason = nil)
      client.api.redact_event(id, event_id, reason: reason)
    end

    def backfill_messages(reverse = false, limit = 10)
      data = client.api.get_room_messages(id, prev_batch, direction: :b, limit: limit)

      events = data[:chunk]
      events.reverse! unless reverse
      events.each do |ev|
        put_event(ev)
      end
    end

    #
    # User Management
    #

    def invite_user(user_id)
      client.api.invite_user(id, user_id)
      true
    rescue MatrixError
      false
    end

    def kick_user(user_id, reason = '')
      client.api.kick_user(id, user_id, reason: reason)
      true
    rescue MatrixError
      false
    end

    def ban_user(user_id, reason = '')
      client.api.ban_user(id, user_id, reason: reason)
      true
    rescue MatrixError
      false
    end

    def unban_user(user_id)
      client.api.unban_user(id, user_id)
      true
    rescue MatrixError
      false
    end

    def leave
      client.api.leave_room(id)
      client.rooms.delete id
      true
    rescue MatrixError
      false
    end

    def set_account_data(type, account_data)
      client.api.set_room_account_data(client.user_id, id, type, account_data)
    end

    def set_user_profile(params = {})
      return nil unless params[:display_name] || params[:avatar_url]
      data = client.api.get_membership(id, client.user_id)
      raise "Can't set profile if you haven't joined the room" unless data[:membership] == 'join'

      data[:displayname] = params[:display_name] unless params[:display_name].nil?
      data[:avatar_url] = params[:avatar_url] unless params[:avatar_url].nil?

      client.api.set_membership(id, client.user_id, 'join', params.fetch(:reason, 'Updating room profile information'), data)
    end

    def tags
      client.api.get_user_tags(client.user_id, id)
    end

    def remove_tag(tag)
      client.api.remove_user_tag(client.user_id, id, tag)
    end

    def add_tag(tag, params = {})
      client.api.add_user_tag(client.user_id, id, tag, params)
    end

    #
    # State updates
    #

    def name=(name)
      client.api.set_room_name(id, name)
      self.name = name
    rescue MatrixError
      nil
    end

    def reload_name!
      data = client.api.get_room_name(id)
      changed = data[:name] != name
      self.name = data[:name] if changed
      changed
    rescue MatrixError
      false
    end

    def topic=(topic)
      client.api.set_room_topic(id, topic)
      self.topic = topic
    rescue MatrixError
      nil
    end

    def reload_topic!
      data = client.api.get_room_topic(id)
      changed = data[:topic] != topic
      self.topic = data[:topic] if changed
      changed
    rescue MatrixError
      false
    end

    def add_alias!(room_alias)
      client.api.set_room_alias(id, room_alias)
      true
    rescue MatrixError
      false
    end

    def reload_aliases!
      data = client.api.get_room_state(id)
      new_aliases = data.find { |chunk| chunk.key?(:content) && chunk[:content].key?(:aliases) }
      return false if new_aliases.nil?

      changed = new_aliases != aliases
      self.aliases = new_aliases if changed
      changed
    rescue MatrixError
      false
    end

    def invite_only=(invite_only)
      self.join_rule = invite_only ? :invite : :public
      @join_rule == :invite # rubocop:disable Lint/Void
    end

    def join_rule=(join_rule)
      client.api.set_join_rule(id, join_rule)
      @join_rule = join_rule
    rescue MatrixError
      nil
    end

    def allow_guests=(allow_guests)
      self.guest_access = (allow_guests ? :can_join : :forbidden)
      @guest_access == :can_join # rubocop:disable Lint/Void
    end

    def guest_access=(guest_access)
      client.api.set_guest_access(id, guest_access)
      @guest_access = guest_access
    rescue MatrixError
      nil
    end

    def modify_user_power_levels(users = nil, users_default = nil)
      return false if users.nil? && users_default.nil?
      data = client.api.get_power_levels(id)
      data[:users_default] = users_default unless users_default.nil?

      if users
        data[:users] = {} unless data.key? :users
        data[:users].merge!(users)
        data[:users].delete_if { |_k, v| v.nil? }
      end

      client.api.set_power_levels(id, data)
      true
    rescue MatrixError
      false
    end

    def modify_required_power_levels(events = nil, params = {})
      return false if events.nil? && (params.nil? || params.empty?)
      data = client.api.get_power_levels(id)
      data.merge!(params)
      data.delete_if { |_k, v| v.nil? }

      if events
        data[:events] = {} unless data.key? :events
        data[:events].merge!(events)
        data[:events].delete_if { |_k, v| v.nil? }
      end

      client.api.set_power.levels(id, data)
    rescue MatrixError
      false
    end

    private

    def ensure_member(member)
      members << member unless members.any? { |m| m.id == member.id }
    end

    def put_event(event)
      @events.push event
      @events.shift if @events.length > @event_history_limit

      fire_event MatrixEvent.new(self, event)
    end

    def put_ephemeral_event(event)
      fire_ephemeral_event MatrixEvent.new(self, event)
    end
  end
end
