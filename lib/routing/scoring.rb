module Routing
  class Scoring
    SIGNALS =['conv','cnts','voll','prio','band','load','keep','turn'].freeze
    WEIGHTS= {'conv'=>0.26,'cnts'=>0.16,'voll'=>0.08,'prio'=>0.06,'band'=>0.10,'load'=>0.12,'keep'=>0.12,'turn'=>0.10}.freeze
    DECLARED=0.35
    EPS = 0.000000001
    def initialize(cfg = {}, his = nil)
      @wgt =WEIGHTS.merge(cfg['weights']||{})
      @dw = (cfg['declared_weight']||DECLARED).to_f
      @bnd=cfg['bands']||[]
      @ovr=cfg['overrides']||{}
      @his =his
    end
    def calc(prv, op, ctx = {})
      sig = SIGNALS.to_h {|s| [s, clip(send(s,prv, op,ctx))] }
      scr= sig.sum {|s, v| v*(@wgt[s]||0.0) }
      { 'score'=>rnd(scr),
        'signals'=>sig.to_h {|s, v| [s, rnd(v)] },
        'weighted'=>sig.to_h {|s, v| [s, rnd(v*(@wgt[s]||0.0))] } }
    end






    def pick(pol, op, ctx = {})
      return {'winner'=>nil,'reason'=>'no_eligible_providers','ranked'=>[]} if pol.nil?||pol.empty?
      rnk= pol.map {|p| [p, calc(p, op, ctx)] }.sort_by {|x| -x[1]['score'] }
      return {'winner'=>rnk[0][0],'reason'=>'only_eligible_provider','ranked'=>rnk} if rnk.size==1
      top = rnk[0][1]['score']
      tie = rnk.select {|x| (x[1]['score']-top).abs<EPS }
      return {'winner'=>rnk[0][0],'reason'=>'best_score','ranked'=>rnk} if tie.size==1
      win = tie.min_by {|x| x[0].num('priority')||99.0 }
      cod= tie.size==rnk.size ? 'all_scores_equal' : 'tie_broken_by_priority'
      {'winner'=>win[0],'reason'=>cod,'ranked'=>rnk}
    end
    def dcsv(rnk, nam)
      own = rnk[nam]
      return nil if own.nil?
      oth = rnk.reject {|k, _| k==nam }.values.max_by {|r| r['score'] }
      return nil if oth.nil?
      own['weighted'].max_by {|s, v| v-oth['weighted'][s].to_f }&.first
    end
    private


    def conv(prv, op, _ctx)
      dec =prv.num('conversion_24h')||0.0
      return dec if @his.nil?
      dec*@dw+@his.bank(prv.name, op.bank)*(1.0-@dw)
    end
    def cnts(prv, _op, ctx)
      tgt =shr(prv, ctx, 'traffic_percentage')
      tot =ctx['total'].to_i
      return tgt.zero? ? 0.5 : 1.0 if tot.zero?
      act =(ctx['counts']||{}).fetch(prv.name, 0).to_f/tot
      0.5+(tgt-act)/2.0
    end
    def voll(prv, _op, ctx)
      tgt =shr(prv, ctx, 'volume_share_pct')
      vol=(ctx['volume']||0).to_f
      return tgt.zero? ? 0.5 : 1.0 if vol.zero?
      act = (ctx['vols']||{}).fetch(prv.name, 0).to_f/vol
      0.5+(tgt-act)/2.0
    end
    def prio(prv, _op, ctx)
      pol = ctx['pool']||[prv]
      lst =pol.map {|p| p.num('priority')||99.0 }.uniq.sort
      return 1.0 if lst.size<2
      pos = lst.index(prv.num('priority')||99.0)
      pos.nil? ? 0.0 : 1.0-pos.to_f/(lst.size-1)
    end
    def band(prv, op, _ctx)
      bnd= @bnd.find {|b| b['max'].nil?||op.amt<=b['max'].to_f }
      pre = bnd.nil? ? [] : (bnd['prefer']||[])
      return room(prv, op) if pre.empty?
      pos= pre.index(prv.name)
      return room(prv, op) if pos.nil?
      pre.size<2 ? 1.0 : 1.0-pos.to_f/(pre.size-1)
    end
    def load(prv, op, _ctx)
      lst = [head(prv.num('daily_amount_limit'), prv.num('daily_approved_amount').to_f+op.amt),
             head(prv.num('in_progress_count_limit'), prv['in_progress_count']+1.0),
             head(prv.num('in_progress_amount_limit'), prv.num('in_progress_amount').to_f+op.amt)].compact
      lst.empty? ? 1.0 : lst.min
    end
    def keep(prv, _op, ctx)
      pol= ctx['pool']||[]
      return 1.0 if pol.size<2
      1.0-(ctx['scarce']||{}).fetch(prv.name, 0.0).to_f
    end
    def turn(prv, op, _ctx)
      cur = prv.num('daily_approved_amount').to_f+op.amt
      hi = fld(prv, 'daily_turnover_max')
      return 0.0 if hi&&cur>hi
      lo = fld(prv, 'daily_turnover_min')
      return 0.5 if lo.nil?||lo<=0||cur>=lo
      0.5+0.5*(lo-cur)/lo
    end
    def tgtv(prv, key)
      (key=='traffic_percentage' ? prv.num(key) : fld(prv, key)||prv.num('traffic_percentage'))||0.0
    end
    def shr(prv, ctx, key)
      own = tgtv(prv, key)
      liv = ctx['live']
      return own/100.0 if liv.nil?||liv.empty?
      sum = liv.sum {|p| tgtv(p, key) }
      sum<=0 ? own/100.0 : own/sum
    end
    def fld(prv, key)
      prv.num(key)||flt((@ovr[prv.name]||{})[key])
    end
    def flt(val)
      val.nil? ? nil : val.to_f
    end
    def room(prv, op)
      lo= prv.num('limit_amount_min')||0.0
      hi= prv.num('limit_amount_max')||op.amt*2.0
      return 0.5 if hi<=lo
      1.0-(op.amt-lo)/(hi-lo)
    end
    def head(lim, use)
      return nil if lim.nil?||lim<=0
      (lim-use)/lim
    end

    
    def clip(val)
      return 0.0 if val.nil?
      val<0.0 ? 0.0 : (val>1.0 ? 1.0 : val)
    end
    def rnd(val)
      (val*10000).round/10000.0
    end
  end
end
