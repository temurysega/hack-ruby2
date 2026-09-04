require 'digest'


module Routing
  class Simulator
    OUTCOMES = ['approved','rejected', 'expired'].freeze
    EXPIRE= 0.55
    REFUSE= 0.08
    LATEMUL = 8.0
    def initialize(cfg = {})
      @out= (cfg['outcomes']||'conversion').to_s
      @ref = (cfg['refusals']||'safe').to_s
      @sed = (cfg['seed']||0).to_i
      @exp = (cfg['expire_share']||EXPIRE).to_f
      @rfs =(cfg['refuse_rate']||REFUSE).to_f
      @lat = (cfg['expire_latency']||LATEMUL).to_f
    end



    def take(prv, op, alt= 1)
      return true if @ref=='off'
      return true if @ref=='safe'&&alt<2
      rndom(op.id, prv.name, 'take')>=@rfs
    end

    def res(prv, op, cnv = nil)
      return 'approved' if @out=='none'
      val = (cnv||prv.num('conversion_24h')||0.5).to_f
      return 'approved' if rndom(op.id, prv.name, 'res')<val
      rndom(op.id, prv.name, 'kind')<@exp ? 'expired' : 'rejected'
    end
    def late(prv, op, out = 'approved')
      bse =(prv.num('avg_latency_sec')||60.0).to_f
      mul = out=='expired' ? @lat : 1.0
      [(bse*mul*(0.6+0.8*rndom(op.id, prv.name, 'late'))).round, 1].max
    end
    def rndom(*key)
      Digest::MD5.hexdigest("#{@sed}|#{key.join('|')}")[0,8].to_i(16)/4294967295.0
    end
  end
end
