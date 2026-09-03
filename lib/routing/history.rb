require 'csv'
module Routing
  class History
    PRIOR=8.0
    def self.load(pth)
      raise ArgumentError,"история не найдена: #{pth}" unless File.file?(pth.to_s)
      rws = CSV.read(pth, headers: true).map(&:to_h)
      raise ArgumentError,'история пуста' if rws.empty?
      new(rws)
    end
    def initialize(rws)
      @tot = Hash.new(0)
      @apr = Hash.new(0)
      @exd = Hash.new(0)
      @lat = Hash.new(0.0)
      @bt = Hash.new(0)
      @ba = Hash.new(0)
      @n = 0
      @a = 0
      rws.each {|r| fill(r) }
      @gl = @n.zero? ? 0.0 : @a.to_f/@n
    end
    def conv(nam)
      n = @tot[nam]
      return @gl if n.zero?
      (@apr[nam]+PRIOR*@gl)/(n+PRIOR)
    end
    def bank(nam, bnk)
      key = [nam,bnk]
      bse = conv(nam)
      n = @bt[key]
      return bse if n.zero?
      (@ba[key]+PRIOR*bse)/(n+PRIOR)
    end
    def expr(nam)
      n = @tot[nam]
      n.zero? ? 0.0 : @exd[nam].to_f/n
    end
    def late(nam)
      n = @tot[nam]
      n.zero? ? 0.0 : @lat[nam]/n
    end
    def stat
      @tot.keys.sort.to_h do |nam|
        [nam, { 'operations'=>@tot[nam],
                'approved'=>@apr[nam],
                'expired'=>@exd[nam],
                'fact_conversion'=>rnd(@apr[nam].to_f/@tot[nam]),
                'smoothed_conversion'=>rnd(conv(nam)),
                'expired_share'=>rnd(expr(nam)),
                'avg_latency_sec'=>rnd(late(nam)) }]
      end
    end
    private
    def fill(r)
      nam = r['payment_system'].to_s
      return if nam.empty?
      sts = r['status'].to_s
      bnk = r['bank'].to_s
      @tot[nam]+=1
      @n+=1
      @lat[nam]+=r['latency_sec'].to_f
      @bt[[nam,bnk]]+=1
      if sts=='approved'
        @apr[nam]+=1
        @a+=1
        @ba[[nam,bnk]]+=1
      end
      @exd[nam]+=1 if sts=='expired'
    end
    def rnd(val)
      (val*10000).round/10000.0
    end
  end
end
