require 'time'
module Routing
  module Models
    class Operation
      def self.list(raw)
        raise ArgumentError,'ожидался массив' unless raw.is_a?(Array)
        raw.each_with_index.map {|r, i| new(r, i) }
      end
      def initialize(raw, idx = 0)
        @raw = raw.is_a?(Hash) ? raw.dup : {}
        @idx = idx
        @bad = false
        @raw['operation_id'] = @raw['operation_id'].to_s
        val = Float(@raw['amount'], exception: false)
        if val.nil?||val<=0
          val = 0.0
          @bad = true
        end
        @amt = val
        @time = pars(@raw['created_at'])
      end
      def bad?
        @bad
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
