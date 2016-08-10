module Lita
  module Adapters
    class Telegram < Adapter
      attr_reader :client

      config :telegram_token, type: String, required: true
      config :botpages_api, type: String, required: false

      def initialize(robot)
        super
        @client = ::Telegram::Bot::Client.new(config.telegram_token, logger: ::Logger.new($stdout))
      end

      def botpage(opts)
        return unless config.botpages_api
        begin
          conn = Faraday.new(:url => 'https://api.botpages.com') do |faraday|
            faraday.request  :url_encoded             # form-encode POST params
            faraday.response :logger                  # log requests to STDOUT
            faraday.adapter  Faraday.default_adapter  # make requests with Net::HTTP
          end

          log.info conn.post("/v1/add_message", { api_key: config.botpages_api}.merge(opts)).body.inspect
        rescue => e
          log.error e.inspect
          Rollbar.error(e)
        end
      end

      def run
        client.listen do |message|
          user = Lita::User.find_by_name(message.from.id)
          user = Lita::User.create(message.from.id, {name: message.from.username, first_name: message.from.first_name, last_name: message.from.last_name}) unless user

          chat = Lita::Room.new(message.chat.id)

          source = Lita::Source.new(user: user, room: chat)

          message.text ||= ''
          msg = Lita::Message.new(robot, message.text, source)

          log.info "Incoming Message: text=\"#{message.text}\" uid=#{source.room}"
          robot.receive(msg)

          botpage(message: message.text, from: source.room, platform: 'telegram')

          user.metadata["blocked"] = nil
          user.save
        end
      end

      def send_messages(target, messages)
        Thread.new do
          attempts = 0
          begin
            opts = messages.pop if messages.last.is_a? Hash
            messages.each do |message|
              log.info "Outgoing Message: text=\"#{message}\" uid=#{target.room.to_i}"
              client.api.sendChatAction(chat_id: target.room.to_i, action: 'typing')
              sleep 2

              if message == messages.last && opts
                if opts[:keyboard].present?
                  markup = ::Telegram::Bot::Types::ReplyKeyboardMarkup.new(keyboard: opts[:keyboard], one_time_keyboard: true)
                else
                  kb = opts[:inline_keyboard].map do |keyboard|
                    ::Telegram::Bot::Types::InlineKeyboardButton.new(text: keyboard.first, url: keyboard.last)
                  end
                  markup = ::Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)
                end
              else
                markup = ::Telegram::Bot::Types::ReplyKeyboardHide.new(hide_keyboard: true)
              end

              client.api.sendMessage(chat_id: target.room.to_i, text: message, reply_markup: markup)
              botpage(message: message, to: target.room.to_i, platform: 'telegram')

              if user = target.user
                user.metadata["blocked"] = nil
                user.save
              end
            end
          rescue ::Telegram::Bot::Exceptions::ResponseError => e
            log.error e.inspect
            if e.error_code.to_s == "403"
              if user = target.user
                user.metadata["blocked"] = "true"
                user.save
                log.error "saved blocked for user: #{user.id}"
              end
            elsif e.error_code.to_s == "429"
              attempts += 1
              unless attempts > 2
                sleep 2
                retry
              else
                Rollbar.error(e)
              end
            else
              Rollbar.error(e)
            end
          rescue => e
            log.error e.inspect
            Rollbar.error(e)
          end
        end
      end

      Lita.register_adapter(:telegram, self)
    end
  end
end
