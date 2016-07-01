module Lita
  module Adapters
    class Telegram < Adapter
      attr_reader :client

      config :telegram_token, type: String, required: true

      def initialize(robot)
        super
        @client = ::Telegram::Bot::Client.new(config.telegram_token, logger: ::Logger.new($stdout))
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
        end
      end

      def send_messages(target, messages)
        Thread.new do
          begin
            opts = messages.pop if messages.last.is_a? Hash
            messages.each do |message|
              log.info "Outgoing Message: text=\"#{message}\" uid=#{target.room.to_i}"
              client.api.sendChatAction(chat_id: target.room.to_i, action: 'typing')
              sleep 2

              if message == messages.last && opts
                markup = ::Telegram::Bot::Types::ReplyKeyboardMarkup.new(keyboard: opts[:keyboard], one_time_keyboard: true)
              else
                markup = ::Telegram::Bot::Types::ReplyKeyboardHide.new(hide_keyboard: true)
              end

              client.api.sendMessage(chat_id: target.room.to_i, text: message, reply_markup: markup)
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
