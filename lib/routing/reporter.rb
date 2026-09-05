module Routing
  class Reporter
    GAPMAX =0.2
    EXPMAX= 0.25
    LOADMAX = 0.9
    DEVMAX= 10.0
    SOFT = ['lower_score','declined_by_provider','reserved_fallback'].freeze
    def initialize(prs, his = nil, cfg = {})
      @prs = prs
      @his = his
      @trn = cfg['turnover']||{}
    end
    def make(dec, ops = [], per = nil)
      raise ArgumentError,'нет решений для отчёта' if dec.nil?||dec.empty?
      rec = tips(dec, ops)
      {'period'=>per.to_s.empty? ? 'не указан' : per.to_s,'total_operations'=>dec.size,'distribution'=>dist(dec, ops),'skip_reasons'=>skip(dec),'not_selected_reasons'=>cnts(dec, true),'projected_daily_utilization'=>util(dec, ops),'outcomes'=>dec.map {|d| d['simulated_result'] }.tally,
       'conversion_calibration'=>calb,
       'recommendations'=>rec.map {|t| t['message'] },'recommendations_detailed'=>rec}
    end
    def dist(dec, ops = [])
      sum= amts(ops)
      cnt = Hash.new(0)
      vls= Hash.new(0.0)
      dec.each do |d|
        cnt[d['selected_provider']] += 1
        vls[d['selected_provider']] += sum[d['operation_id']].to_f
      end
      tot= dec.size.to_f
      vol = vls.values.sum
      (@prs.map(&:name)|cnt.keys).to_h do |nam|
        shr = cnt[nam]*100.0/tot
        tgt= prv(nam)&.num('traffic_percentage').to_f
        [nam, {'count'=>cnt[nam],'share_pct'=>pct(shr),'target_pct'=>pct(tgt),
               'deviation_pp'=>pct(shr-tgt),'volume'=>vls[nam].round,
               'volume_share_pct'=>vol.zero? ? 0.0 : pct(vls[nam]*100.0/vol)}]
      end
    end
    def skip(dec)
      cnts(dec, false)
    end
    def util(dec, ops =[])
      sum= amts(ops)
      add= Hash.new(0.0)
      dec.each {|d| add[d['selected_provider']] += sum[d['operation_id']].to_f if d['simulated_result']=='approved' }
      @prs.to_h do |p|
        lim= p.num('daily_amount_limit')
        use= p.num('daily_approved_amount').to_f+add[p.name]
        low = mini(p)
        [p.name, {'start'=>p.num('daily_approved_amount').to_f.round,'added_by_queue'=>add[p.name].round,'used'=>use.round,'limit'=>lim&.round,
                  'utilization_pct'=>lim.nil?||lim.zero? ? nil : pct(use*100.0/lim),
                  'turnover_min'=>low&.round,'turnover_min_met'=>low.nil? ? nil : use>=low}]
      end
    end
    def calb
      return {} if @his.nil?
      @prs.reject(&:own?).to_h do |p|
        dcl= p.num('conversion_24h').to_f
        act= @his.conv(p.name)
        [p.name, {'declared'=>dcl,'actual_smoothed'=>pct(act, 4),'gap'=>pct(act-dcl, 4),
                  'expired_share'=>pct(@his.expr(p.name), 4),'avg_latency_sec'=>pct(@his.late(p.name))}]
      end
    end
    def tips(dec, ops = [])
      out = []
      dst= dist(dec, ops)
      utl = util(dec, ops)
      @prs.reject(&:own?).each do |p|
        nam = p.name
        out << gapt(p, nam) if @his && (p.num('conversion_24h').to_f-@his.conv(nam))>GAPMAX
        out << expt(nam) if @his && @his.expr(nam)>EXPMAX
        out << ldt(nam, utl[nam]) if utl[nam]['utilization_pct'].to_f>LOADMAX*100
        out << devt(nam, dst[nam]) if dst[nam] && dst[nam]['deviation_pp'].abs>DEVMAX
        out << lowt(nam, utl[nam]) if utl[nam]['turnover_min_met']==false
      end
      fbk = dec.count {|d| d['selected_provider']==Models::Provider::SELFPROVIDER }
      out << fbkt(fbk, dec.size) if fbk.positive?
      out.empty? ? [nrm] : out
    end
    private
    def cnts(dec, sft)
      cnt= Hash.new(0)
      dec.each do |d|
        (d['attempts']||[]).each do |a|
          next unless a['decision']=='skipped'
          cnt[a['reason']] += 1 if SOFT.include?(a['reason'])==sft
        end
      end
      cnt.sort_by {|_,v| -v }.to_h
    end
    def pct(val, dig = 1)
      return nil if val.nil?
      (val.to_f*10**dig).round/(10.0**dig)
    end
    def prv(nam)
      @prs.find {|p| p.name==nam }
    end
    def amts(ops)
      (ops||[]).to_h {|o| [o.id, o.amt] }
    end
    def mini(prv)
      prv.num('daily_turnover_min')||(@trn[prv.name]||{})['daily_turnover_min']&.to_f
    end
    def gapt(prv, nam)
      dcl = prv.num('conversion_24h').to_f
      act = @his.conv(nam)
      {'code'=>'conversion_overstated','severity'=>'high','provider'=>nam,'parameter'=>'traffic_percentage',
       'evidence'=>"заявлено #{dcl}- фактически #{pct(act, 3)} по #{@his.stat[nam]['operations']} операциям",
       'message'=>"#{nam} заявленная конверсия завышена на #{pct(dcl-act, 3)} снизить traffic_percentage с #{prv.num('traffic_percentage').to_i}"}
    end
    def expt(nam)
      {'code'=>'high_expired_share','severity'=>'high','provider'=>nam,'parameter'=>'avg_latency_sec',
       'evidence'=>"просрочек #{pct(@his.expr(nam)*100)}% при средней задержке #{pct(@his.late(nam))} c",
       'message'=>"#{nam} каждая #{(1/@his.expr(nam)).round} заявка уходит в просрочку -посмотреть таймаут провайдера"}
    end
    def ldt(nam, u)
      {'code'=>'daily_limit_near','severity'=>'medium','provider'=>nam,'parameter'=>'daily_amount_limit',
       'evidence'=>"использовано #{u['used']} из #{u['limit']} (#{u['utilization_pct']}%)",
       'message'=>"#{nam} дневной лимит выбран на #{u['utilization_pct']}% -поднять дневной лимит или снизить долю"}
    end
    def devt(nam, d)
      {'code'=>'share_deviation','severity'=>'medium','provider'=>nam,'parameter'=>'traffic_percentage',
       'evidence'=>"факт #{d['share_pct']}% против цели #{d['target_pct']}%",
       'message'=>"#{nam} отклонение доли #{d['deviation_pp']} п.п. -пересмотреть процентр траффика или веса профиля"}
    end
    def lowt(nam, u)
      {'code'=>'turnover_min_unmet','severity'=>'high','provider'=>nam,'parameter'=>'daily_turnover_min',
       'evidence'=>"оборот #{u['used']} при обязательстве #{u['turnover_min']}",
       'message'=>"#{nam} недобор обязательного оборота #{(u['turnover_min']-u['used']).round} -повысить вес в профиле"}
    end
    def fbkt(num, tot)
      {'code'=>'self_provider_used','severity'=>'high','provider'=>Models::Provider::SELFPROVIDER,'parameter'=>'banks',
       'evidence'=>"#{num} из #{tot} заявок ушли на self-провайдера",
       'message'=>"внешние провайдеры не покрыли #{pct(num*100.0/tot)}% заявок -расширить диапазоны сумм"}
    end
    def nrm
      {'code'=>'no_issues','severity'=>'info','provider'=>nil,'parameter'=>nil,
       'evidence'=>'отклонений выше порогов не обнаружено',
       'message'=>'конфигурация роутинга работает штатно'}
    end
  end
end
