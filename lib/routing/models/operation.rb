require 'time'
module Routing
  module Models
    class Operation
      def self.list(raw)
        raise ArgumentError,'ожидался массив' unless raw.is_a?(Array)
        out = raw.each_with_index.map {|r, i| new(r, i) }
        dup =out.map(&:id).tally.select { |_, c| c > 1}.keys
        raise ArgumentError,"дубли операций #{dup.join(', ')}" if dup.any?
        out
      end





      def initialize(raw, idx = 0)
        raise ArgumentError,'ожидался объект' unless raw.is_a?(Hash)
        raise ArgumentError,'пустой айдишнмик' if raw['operation_id'].to_s.strip.empty?
        val = Float(raw['amount'], exception: false)
        raise ArgumentError,"#{raw['operation_id']} некорректное количествол" if val.nil?||val<=0
        @raw =raw.dup
        @idx= idx
        @amt= val
        @time =pars(raw['created_at'])
      end
      def [](key)
        @raw[key]
      end
      def id
        @raw['operation_id']
      end
      def amt
        @amt
      end
      def bank
        @raw['bank'].to_s
      end
      def time
        @time
      end
      def seq
        @idx
      end
      def to_h
        @raw.dup
      end
      private
      def pars(val)
        return nil if val.to_s.strip.empty?
        Time.parse(val.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
