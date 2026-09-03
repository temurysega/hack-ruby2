module Routing
  module Models
    class Provider
      SELF_PROVIDER ='spacepayments'.freeze
      MONEY_COUNTERS= %w[daily_approved_amount in_progress_amount].freeze
      UNIT_COUNTERS = %w[in_progress_count available_requisites].freeze
      def self.list(raw)
        raise ArgumentError,'ожидался массив' unless raw.is_a?(Array)
        out = raw.map {|r| new(r) }
        dup = out.map(&:name).tally.select { |_, c| c > 1}.keys
        raise ArgumentError, "providers: дубли payment_system: #{dup.join(', ')}" if dup.any?
        out
      end
      def initialize(raw)
        raise ArgumentError,'ожидался объект' unless raw.is_a?(Hash)
        raise ArgumentError, 'пустая платежка' if raw['payment_system'].to_s.strip.empty?
        @raw = raw.dup
        MONEY_COUNTERS.each { |k| @raw[k] = @raw[k].to_f }
        UNIT_COUNTERS.each { |k| @raw[k] = @raw[k].to_i }
        @raw['dispatch_times'] = []
      end
      def [](key)
        @raw[key]
      end
      def name
        @raw['payment_system']
      end
      def own?
        name ==SELF_PROVIDER
      end
      def num(key)
        val = @raw[key]
        val.nil? ? nil : val.to_f
      end
      def hold(amt, now)
        @raw['in_progress_count'] += 1
        @raw['in_progress_amount'] += amt
        @raw['available_requisites'] -= 1
        @raw['dispatch_times'] << now
        self
      end
      def fin(res, amt)
        @raw['in_progress_count'] = [@raw['in_progress_count'] - 1, 0].max
        @raw['in_progress_amount'] = [@raw['in_progress_amount'] - amt, 0.0].max
        @raw['available_requisites'] += 1
        @raw['daily_approved_amount'] += amt if res == 'approved'
        self
      end
      def to_h
        @raw.dup
      end
    end
  end
end
