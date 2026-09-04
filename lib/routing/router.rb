module Routing
  class Router
    STEP= 30.0
    HORIZON=50
    SCARMUL= 8.0
    def initialize(prs, con, sco, sim)
      @prs= prs
      @con = con
      @sco = sco
      @sim= sim
      @cnt=Hash.new(0)
      @vls= Hash.new(0.0)
      @tot= 0
      @vol= 0.0
      @liv = []
      @bse=0.0
      @stp= STEP
    end
    def run(ops)
      raise ArgumentError,'очередь пуста' if ops.nil?||ops.empty?
      tms =ops.map(&:time).compact.sort
      @bse = tms.empty? ? 0.0 : tms.first.to_f
      @stp =step(tms)
      out = ops.each_with_index.map {|op, i| one(op, ops[i+1, HORIZON]||[]) }
      free(Float::INFINITY)
      out
    end


    def one(op,rest=[])
      now=tick(op)
      free(now)
      bad=@con.scan(@prs, op, now)
      ext =@prs.reject {|p| bad[p.name]||p.own? }
      cxt = ctx(ext, rest)
      rnk = {}
      ref =[]
      win =nil
      why ='no_eligible_providers'
      while win.nil?
        cnd = ext.reject {|p| ref.include?(p.name) }
        sel = @sco.pick(cnd, op, cxt.merge('pool'=>cnd))
        sel['ranked'].each {|p, r| rnk[p.name] ||= r }
        break if sel['winner'].nil?
        if @sim.take(sel['winner'], op, cnd.size)
          win = sel['winner']
          why = sel['reason']
        else
          ref<< sel['winner'].name
        end
      end
      if win.nil?
        win= fall
        why= ref.empty? ? 'no_eligible_providers' : 'all_providers_declined'
      end
      res =@sim.res(win, op, rnk.dig(win.name, 'signals', 'conv'))
      lat =@sim.late(win, op, res)
      win.hold(op.amt, now)
      @liv << [now+lat, win, op.amt, res]
      @cnt[win.name] += 1
      @vls[win.name] += op.amt
      @tot += 1
      @vol += op.amt
      { 'operation_id'=>op.id,'selected_provider'=>win.name,'attempts'=>attempts(bad, win, why, rnk, ref),'simulated_result'=>res, 'latency_sec'=>lat }
    end
    def attempts(bad, win, why, rnk, ref)
      @prs.map do |p|
        nam = p.name
        if nam==win.name
          {'provider'=>nam,'decision'=>'selected','reason'=>why,'details'=>desc(why, nam, rnk),
           'score'=>rnk.dig(nam,'score'),'signals'=>rnk.dig(nam,'signals')}
        elsif bad[nam]
          {'provider'=>nam,'decision'=>'skipped','reason'=>bad[nam]['reason'],'details'=>bad[nam]['details']}
        elsif ref.include?(nam)
          {'provider'=>nam,'decision'=>'skipped','reason'=>'declined_by_provider',
           'details'=>'отказал в приёме заявка передана следующему','score'=>rnk.dig(nam,'score')}
        elsif rnk.key?(nam)
          {'provider'=>nam,'decision'=>'skipped','reason'=>'lower_score',
           'details'=>"оценка #{rnk.dig(nam,'score')} против #{rnk.dig(win.name,'score')} у #{win.name}",
           'score'=>rnk.dig(nam,'score'),'signals'=>rnk.dig(nam,'signals')}
        else
          {'provider'=>nam,'decision'=>'skipped','reason'=>'reserved_fallback',
           'details'=>'self-провайдер, внешние кандидаты доступны'}
        end
      end
    end
    def stat
      {'counts'=>@cnt.dup,'volumes'=>@vls.dup,'total'=>@tot,'volume'=>@vol}
    end
    private
    def tick(op)
      op.time ? op.time.to_f : @bse+op.seq*@stp
    end
    def step(tms)
      return STEP if tms.size<2
      gap= tms.each_cons(2).map {|a, b| (b-a).to_f }.reject {|v| v<=0 }.sort
      gap.empty? ? STEP : gap[gap.size/2]
    end
    def free(now)
      don, @liv =@liv.partition {|x| x[0]<=now }
      don.each {|_,prv, amt,res| prv.fin(res, amt) }
    end
    def fall
      @prs.find(&:own?)||@prs.last
    end
    def ctx(pol, rest)
      {'pool'=>pol,'total'=>@tot,'volume'=>@vol,'counts'=>@cnt,'vols'=>@vls,'scarce'=>scar(rest)}
    end



    def scar(rest)
      return {} if rest.nil?||rest.empty?
      cnt = Hash.new(0)
      rest.each do |o|
        e = @con.pass(@prs, o).reject(&:own?)
        cnt[e.first.name] += 1 if e.size==1
      end
      cnt.transform_values {|v| [v.to_f/rest.size*SCARMUL, 1.0].min }
    end
    def desc(why, nam, rnk)
      return 'единственный допустим провайдер' if why=='only_eligible_provider'
      return 'внешние провайдеры недоступны- включён self-провайдер' if why=='no_eligible_providers'
      return 'все внешние провайдеры отказали, включён self-провайдер' if why=='all_providers_declined'
      return 'кандидаты равны- выбран по приоритету' if why=='all_scores_equal'
      oth = rnk.reject {|k, _| k==nam }.values.map {|r| r['score'] }
      oth.empty? ? "оценка #{rnk.dig(nam,'score')}" : "оценка #{rnk.dig(nam,'score')} против #{oth.max}"
    end
  end
end
